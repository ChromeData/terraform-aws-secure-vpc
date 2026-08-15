# Lab notes

The decisions, the mistakes, and the things I would do differently. The README says what this is. This says why it is shaped like that.

***

## Why extract a module at all

The honest trigger was not "duplication is bad." It was drift.

Labs 12 and 13 each hand-wrote a VPC. Twenty-two near-identical resources between them. Then lab 12's verifier caught something: the VPC's default security group, which AWS creates automatically and which cannot be deleted, was sitting there allowing all outbound traffic. Anything launched without an explicit security group lands in it. Every group I had written myself was correct, and the one I had not written was the hole.

Lab 13 got that fix too, but only because I happened to remember. There is no mechanism in a copy-pasted VPC that carries a fix forward. A third lab would have shipped with the same hole, and the fourth would have too.

That is what a module is for. Not tidiness. A place for a fix to live so it reaches everything downstream.

***

## The defaults are inverted on purpose

`terraform-aws-modules/vpc`, which is the module almost everyone uses, defaults `enable_nat_gateway` to `false` as well, but the ecosystem around it does not: nearly every blog post, tutorial, and internal wrapper turns it on, and it becomes the shape people copy.

The reasoning here:

**A NAT gateway costs about $32 a month per availability zone.** Three AZs is roughly $96 before a byte of data moves through it. That is not a rounding error in a lab and it is not a rounding error across an organisation's dev accounts either.

**It puts an egress path into the tier defined by not having one.** "Private subnet" is not a property of a subnet. It is a property of its route table. A private subnet with a default route to a NAT gateway is a subnet with a name.

**Most things that need it do not.** The common case is a workload that needs S3. Gateway endpoints are free, route over the AWS network, and let a subnet with no internet route at all reach S3 and DynamoDB. That is why `gateway_endpoints` defaults to `["s3"]` while NAT defaults to off.

Lab 13 is the proof rather than the argument. Its instances serve a page with no package installs, using only what ships on the Amazon Linux AMI, specifically so the private tier can stay sealed. The first version ran `dnf install nginx` and every instance failed its health check forever, because I had built a network for isolation and then written a deploy that assumed internet access. The cheap fix was a NAT gateway. The correct fix was to stop needing one.

***

## The test suite was broken and reported success

This is the mistake worth reading.

The first version of `tests/validation.tftest.hcl` ran green on my machine. Nine tests, all passing. I nearly shipped it.

Running it in a clean environment gave this:

```
Error: Retrieving AWS account details: validating provider credentials:
retrieving caller identity from STS: operation error STS: GetCallerIdentity,
https response error StatusCode: 403, api error InvalidClientTokenId

Failure! 0 passed, 1 failed, 8 skipped.
```

Even with `command = plan`, the AWS provider validates credentials during init. So the entire file aborted on the first run block and the other eight reported **skip**.

Look at that word. Not "fail." A CI summary showing `0 failed` with eight skips looks fine at a glance, and skips are the single easiest failure mode to scroll past. This is the fourth time in this portfolio that a green or quiet result turned out to mean "the check never executed" — a scanner that crashed and got scored as clean, a lint config whose path filter matched zero files, a pytest skip guard sitting in a helper module that never gets collected, and now this.

`mock_provider` fixes it properly. No credentials, no API calls, no cost, and identical behaviour on a laptop and in CI.

The tradeoff is real and I would rather say it than have somebody discover it: **mocked providers never call AWS.** These tests prove the module's logic. They do not prove AWS accepts the plan. Those are different things and one does not substitute for the other. The examples directory and a real apply cover the second half.

***

## Then I broke it on purpose

Having been wrong about a green result four times, the number by itself does not persuade me any more. So each test got a positive control: a deliberate break, and a check that the suite noticed.

Three breaks, chosen because they are mistakes a real person makes rather than nonsense that would fail anything:

**NAT always on.** Nobody does this maliciously. Somebody does it because the module did not work for their case and this made it work. Two tests failed, seven stayed green.

**One shared private route table instead of one per AZ.** This looks like cleanup. It is what lab 13 originally did. With NAT off it changes nothing, which is precisely why it survives review, and the moment egress is added every AZ routes through one gateway. Caught.

**Dropped the offset in the subnet arithmetic**, so private subnets reuse the public ranges. Caught at plan time. Without the test it surfaces as `InvalidSubnet.Conflict` from the AWS API partway through an apply, pointing at the API call rather than the line of arithmetic. That difference is most of an afternoon.

The part I care about as much as the catches: the unrelated tests stayed quiet every time. Assertions that fire on any change at all are noise, and noisy suites get ignored, which is a slower path to the same place as having no suite.

Full transcripts in [`findings/test-positive-controls.txt`](./findings/test-positive-controls.txt).

***

## Refactoring lab 13 onto it, and the thing that nearly ate the network

An interface is a claim until something consumes it. So lab 13's network file went from 130 hand-written lines to a module call, and the exercise immediately found something.

Moving a resource into a module changes its address in state. Terraform tracks resources by address. So a purely cosmetic refactor reads to Terraform as: delete all of this, create all of that. On a live environment that is the VPC destroyed and rebuilt, the subnets with it, the instances in them, and a new DNS name on the load balancer.

I did not want to assert that from memory and I was not going to pay to confirm it, so I reproduced it offline with the null provider. Same structural change, three resources into a module, no cloud:

```
without moved blocks    Plan: 3 to add, 0 to change, 3 to destroy
with moved blocks       Plan: 0 to add, 0 to change, 0 to destroy
```

Nine `moved` blocks went into lab 13. Two of them are not clean one-to-one mappings and the file says so: the old config had a single shared private route table where the module makes one per AZ, so the existing table becomes index 0 and index 1 is genuinely new. The private route table association for the second AZ then points somewhere different, and `route_table_id` cannot be updated in place, so that association is replaced. On a tier with no routes in it that is a few seconds of nothing, but it belongs in a plan review rather than in a surprise.

**Scope, honestly:** the mechanic is proven with real state and real plan output. Those nine specific blocks are not, because lab 13's infrastructure was destroyed after its chaos test and there is no live state left to move. `terraform validate` resolves moved-block addresses, so they are checked for correctness, and that is the whole of it.

Written up in lab 13's [`findings/state-move-proof.txt`](../13-ha-application-platform/findings/state-move-proof.txt).

***

## What I would do differently

**Version it for real.** Lab 13 sources the module by relative path because both live in one repository. That means a change to the module changes every consumer on the next apply, with no version bump and nothing to review, which is the exact problem versioning exists to solve. The pinned git-ref form is written in the file as a comment. It should be the actual source, with the module in its own repository and a tag.

**No `terraform apply` against real AWS with NAT on.** The plan is verified. The running behaviour is not. Everything I claim about NAT gateway routing in this module comes from the plan and from documentation, not from having watched a packet traverse it. That is a genuine gap and no amount of test coverage closes it.

**The interface is small because it has one consumer.** That is currently a strength and it will become a weakness. The first time somebody needs an interface endpoint, or IPv6, or a subnet layout this does not produce, the answer is either a breaking change or a fork. A module with one owner can hold an opinion. A module with five needs a deprecation policy, and I have not written one.
