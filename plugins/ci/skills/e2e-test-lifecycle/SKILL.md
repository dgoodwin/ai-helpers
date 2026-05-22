---
name: e2e-test-lifecycle
description: Manage OpenShift Ginkgo e2e test suite membership, lifecycle promotion, and shard rebalancing using OTE labels and Sippy data
---

# E2E Test Lifecycle Management

Manage OpenShift Ginkgo e2e tests: organize into suites, promote between suites based on stability data, and rebalance shards for optimal CI job runtimes.

## When to Use This Skill

Use this skill when you need to:

- Assign a test to a suite or move it between suites
- Promote tests from `active` to `stable` based on pass rate and age
- Identify tests in `openshift/conformance` that should migrate to feature-specific or `active`/`stable` suites
- Rebalance test shards (`stable-01`, `stable-02`, etc.) based on job runtime data
- Audit suite membership for a component or SIG
- Set a test's lifecycle to `Informing` during its stabilization period
- Create or modify feature suites that compose into the new suite hierarchy

## Prerequisites

1. **Repository context**: Must be run inside a repository containing OpenShift Ginkgo e2e tests. This is typically `openshift/origin` but increasingly component repos using the OpenShift Tests Extension (OTE) framework.

2. **Build the test binary** (origin only):
   ```bash
   make build
   ```
   This produces the `openshift-tests` binary which can list test metadata.

3. **Sippy access**: For querying test pass rates and job runtimes, use the `ci:fetch-test-runs` and `ci:ask-sippy` skills. Authentication may be required via `ci:oc-auth`.

## Suite Architecture

### Legacy Suites (Shrink Over Time)

These suites are overcrowded and should contain only core smoke-test functionality confirming nothing is seriously broken in an OpenShift cluster:

| Suite | Purpose |
|-------|---------|
| `openshift/conformance/parallel` | Core parallel smoke tests |
| `openshift/conformance/serial` | Core serial smoke tests |
| `openshift/conformance` | Union of parallel + serial conformance |

### New Suite Hierarchy

Tests graduate through a lifecycle of suites. Feature suites compose into these parent suites:

| Suite | Purpose | Parallelism |
|-------|---------|-------------|
| `openshift/active` | Recent or actively developed features, parallel-safe | parallel |
| `openshift/active-serial` | Recent or actively developed features, must run serially | serial |
| `openshift/stable-NN` | Graduated stable tests, parallel-safe, explicitly sharded (e.g., `stable-01`, `stable-02`) | parallel |
| `openshift/stable-serial-NN` | Graduated stable tests, must run serially, explicitly sharded | serial |

### Feature Suites

Teams define feature-specific suites (e.g., `openshift/network/ipsec`, `openshift/etcd/scaling`) that compose into the parent suites above via OTE's `Parents` field. A feature suite can move between parent suites over time (e.g., from `active` to `stable-01`) by changing its parent declaration.

### Composition Model

OTE supports suite composition through the `Parents` field. A child suite's tests are automatically included when the parent suite runs:

```go
ext.AddSuite(e.Suite{
    Name:    "mycomponent/feature-x",
    Parents: []string{"openshift/active"},
})
```

To move a feature suite from `active` to `stable-01`, update its parent:

```go
ext.AddSuite(e.Suite{
    Name:    "mycomponent/feature-x",
    Parents: []string{"openshift/stable-01"},
})
```

Global suites can also use CEL qualifier expressions to filter tests by labels across all extensions:

```go
ext.AddGlobalSuite(e.Suite{
    Name: "openshift/active",
    Qualifiers: []string{
        `labels.exists(l, l=="ACTIVE")`,
    },
})
```

### Explicit Sharding

We intentionally do not rely on the pre-existing auto-sharding mechanism. Auto-sharding does not work in constrained environments like vSphere where concurrent batches of jobs cannot be spun up. Instead, we use explicit shards (`stable-01`, `stable-02`, etc.) that can be scheduled at different times.

Each shard is a separate suite with its own CI job. Tests are assigned to shards to keep job runtimes roughly balanced.

## Test Lifecycle

### 1. New Test (Informing)

A new test starts with the `Informing` lifecycle, allowing failures to be non-blocking for 2-3 sprints while stability is improved:

```go
import (
    g "github.com/onsi/ginkgo/v2"
    ote "github.com/openshift-eng/openshift-tests-extension/pkg/ginkgo"
)

var _ = g.Describe("[sig-network] My new feature test", func() {
    g.It("should do the thing", ote.Informing(), func() {
        // test implementation
    })
})
```

The test should be in the `active` or `active-serial` suite at this point.

### 2. Active (Blocking)

Once the test achieves >= 99% pass rate over a sustained period, remove the `Informing()` decorator. The test remains in `active`/`active-serial`.

### 3. Stable (Graduated)

After the feature GAs (typically one release after GA), and the test has a sustained very high pass rate (>= 99.5%), promote it to a `stable-NN` or `stable-serial-NN` shard.

### 4. Conformance Candidates

Only tests verifying the most fundamental cluster smoke-test functionality belong in `openshift/conformance`. Most tests should NOT be in conformance.

## Implementation Steps

### Listing Tests and Their Metadata

In `openshift/origin`, build and use the `openshift-tests` binary:

```bash
make build
./openshift-tests list --output json          # list all tests with metadata
./openshift-tests list --suite <suite-name>   # list tests in a specific suite
```

<!-- TODO: Figure out how to list tests from OTE extension binaries. Running
`openshift-tests list` in origin does not show tests from extensions by default.
Extensions are discovered from release payload images at runtime. We may need
a running payload or a local extension binary to enumerate extension tests.
Investigate whether `openshift-tests list --extensions-path <dir>` or similar
exists, or if we need to run each extension binary's own `list` subcommand
individually. -->

For OTE extension binaries in component repos:

```bash
./<extension-binary> list                     # list all tests
./<extension-binary> list --suite <suite>     # list tests in a suite
./<extension-binary> info                     # show suites, labels, metadata
```

### Labeling Tests for Suite Membership

The preferred approach is OTE labels on test specs, not `[Suite:...]` tags in test names:

```go
// In your extension's main.go or test registration code:
specs, err := g.BuildExtensionTestSpecsFromOpenShiftGinkgoSuite()

// Label tests for the active suite
specs.Select(et.NameContains("[sig-network] my feature")).AddLabel("ACTIVE")

// Label tests for stable sharding
specs.Select(et.NameContains("[sig-auth] LDAP")).AddLabel("STABLE")
specs.Select(et.NameContains("[sig-auth] LDAP")).AddLabel("SHARD-01")
```

Then define suites that filter on these labels:

```go
ext.AddSuite(e.Suite{
    Name:       "openshift/active",
    Qualifiers: []string{`labels.exists(l, l=="ACTIVE")`},
})

ext.AddSuite(e.Suite{
    Name:       "openshift/stable-01",
    Qualifiers: []string{`labels.exists(l, l=="STABLE") && labels.exists(l, l=="SHARD-01")`},
})
```

### Querying Test Stability from Sippy

Use CI plugin skills to get pass rate data for promotion decisions:

```bash
# Query test pass rates for a specific test
/ci:ask-sippy "What is the pass rate for test '[sig-network] Services should serve endpoints on same port and different protocols' over the last 30 days in 4.19?"

# Query job runtimes for shard rebalancing
/ci:ask-sippy "What is the average runtime for job periodic-ci-openshift-release-master-nightly-4.19-e2e-aws-ovn-stable-01 over the last 14 days?"

# Get test run details
/ci:fetch-test-runs --test-name "<test name>" --release "4.19"
```

### Promoting Tests Between Suites

When promoting a test from `active` to `stable`:

1. **Check stability**: Query Sippy for the test's pass rate over the last 30 days. Require >= 99.5%.
2. **Check age**: The feature should be GA for at least one release.
3. **Update labels**: Replace `ACTIVE` label with `STABLE` and assign a `SHARD-NN`.
4. **Choose shard**: Pick the shard with the lowest total runtime to keep jobs balanced.

### Rebalancing Shards

When shard runtimes diverge significantly:

1. **Gather runtime data**: Query Sippy for average job runtime of each shard.
2. **Gather per-test runtimes**: Get runtime for each test in the overloaded shard.
3. **Calculate moves**: Identify tests to move from the heaviest shard to the lightest.
4. **Update shard labels**: Change `SHARD-NN` labels on the tests being moved.
5. **Target balance**: Aim for all shards within 10% of mean runtime.

When all existing shards are full (runtimes too long even after rebalancing), create a new shard:

1. Define a new suite `openshift/stable-NN+1`
2. Create a corresponding CI job
3. Move tests from overloaded shards into the new shard

### Migrating Tests Out of Conformance

To identify conformance tests that should move to `active` or `stable`:

1. List tests in conformance:
   ```bash
   ./openshift-tests list --suite openshift/conformance/parallel
   ```
2. For each test, check if it's truly a core smoke test or if it tests a specific feature.
3. Feature-specific tests should move to a feature suite under `active` or `stable`.
4. Update the test's suite tag or label accordingly.
5. Verify the test still runs in at least one CI job after the move.

## Test Requirements Checklist

Before assigning a test to any suite, verify:

- [ ] Test has a `[Jira:Component]` tag or ci-test-mapping entry for ownership
- [ ] Test produces deterministic pass/fail results (no pass-only-on-failure)
- [ ] Test name is stable (no dynamic content like pod UIDs or timestamps)
- [ ] Test has `[sig-XYZ]` tag for area grouping
- [ ] Test has appropriate `[FeatureGate:XYZ]` or `[Capability:XYZ]` annotations
- [ ] Test duration is under 5 minutes (longer tests need architect approval)
- [ ] Parallel tests are non-disruptive and can run alongside any other test
- [ ] Serial tests restore cluster to original state after completion
- [ ] Test passes at >= 99% for blocking status (or has `Informing()` lifecycle)

## Recommended Payload Jobs for Validation

After changing suite membership, run payload jobs to validate:

For parallel suite changes:
```
/payload-job periodic-ci-openshift-hypershift-release-4.22-periodics-e2e-aws-ovn-conformance
/payload-job periodic-ci-openshift-release-master-nightly-4.22-e2e-metal-ipi-ovn-ipv6
/payload-job periodic-ci-openshift-release-master-ci-4.22-e2e-aws-upgrade-ovn-single-node
```

For serial suite changes:
```
/payload-job periodic-ci-openshift-hypershift-release-4.22-periodics-e2e-aws-ovn-conformance-serial
/payload-job periodic-ci-openshift-release-master-nightly-4.22-e2e-aws-ovn-single-node-serial
```

## Examples

### Example 1: Add a New Test to the Active Suite

```go
var _ = g.Describe("[sig-storage] CSI volume snapshot", func() {
    g.It("should create and restore a volume snapshot", ote.Informing(), func() {
        // test implementation
    })
})

// In extension registration:
specs.Select(et.NameContains("[sig-storage] CSI volume snapshot")).AddLabel("ACTIVE")
```

### Example 2: Promote a Test from Active to Stable

After confirming >= 99.5% pass rate and feature GA:

```go
// Remove Informing() decorator from the test if still present

// Update label: remove ACTIVE, add STABLE + shard assignment
specs.Select(et.NameContains("[sig-storage] CSI volume snapshot")).AddLabel("STABLE")
specs.Select(et.NameContains("[sig-storage] CSI volume snapshot")).AddLabel("SHARD-01")
// (remove the ACTIVE label if previously set)
```

### Example 3: Define a Feature Suite Composing into Active

```go
ext.AddSuite(e.Suite{
    Name:    "mycomponent/csi-snapshots",
    Parents: []string{"openshift/active"},
    Qualifiers: []string{
        `labels.exists(l, l=="CSI-SNAPSHOTS")`,
    },
})
```

Later, when promoting to stable:

```go
ext.AddSuite(e.Suite{
    Name:    "mycomponent/csi-snapshots",
    Parents: []string{"openshift/stable-02"},
    Qualifiers: []string{
        `labels.exists(l, l=="CSI-SNAPSHOTS")`,
    },
})
```

### Example 4: Rebalance Shards

```
User: The stable-01 job is running 45 minutes but stable-02 only runs 25 minutes. Rebalance them.

Steps:
1. Query per-test runtimes in stable-01 via Sippy
2. Identify ~10 minutes of tests to move from stable-01 to stable-02
3. Update SHARD-01 → SHARD-02 labels on selected tests
4. Verify both shards are ~35 minutes after the change
```

## Notes

- The `openshift/conformance` suites should shrink over time. Only core smoke-test functionality belongs there.
- Feature suites compose into parent suites via the OTE `Parents` field. Move a feature between suites by updating its parent.
- Always use OTE labels (`AddLabel`) and suite `Qualifiers` (CEL expressions) for suite membership. This is the forward-looking approach preferred over `[Suite:...]` tags in test names.
- Explicit sharding (`stable-01`, `stable-02`) is used instead of auto-sharding because auto-sharding does not work in constrained environments like vSphere.
- Tests ported from `openshift-tests-private` should include the `[OTP]` annotation. Tests ported from Level 0 should include `[Level0]`.
- Use `Informing()` lifecycle for new tests during their 2-3 sprint stabilization period.

## See Also

- Related Skill: `ci:ask-sippy` (query test pass rates and job runtimes)
- Related Skill: `ci:fetch-test-runs` (get detailed test run data)
- Related Skill: `ci:fetch-test-report` (get test reports for a job)
- Related Skill: `ci:oc-auth` (authenticate for Sippy access)
