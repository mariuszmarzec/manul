# Manul Unit Testing Guide

This guide applies whenever a repository task requires adding or changing unit tests. It supplements the repository's test conventions and the general, language-agnostic guidelines in `skills/unit-testing-language-agnostic/SKILL.md`.

## Core rule

A unit test must prove behavior, not merely prove that objects can be constructed, methods can be called, or helper functions return expected values.

A useful test should fail if the requested production behavior is removed or broken.

Before writing the test:

1. Identify the exact behavior requested by the task or review comment.
2. Identify the production entry point that exercises that behavior.
3. Find existing unit tests for that class, component, or use case and extend them when appropriate.
4. Inspect the real dependencies and existing test infrastructure before choosing mocks.
5. Define the observable result that proves the behavior.

## Assertions: compare complete values by default

Prefer the smallest set of assertions that clearly proves the intended behavior.

When a repository/service returns a value object, data class, record, DTO, model, entity, collection, or other type with meaningful value equality, compare the **whole expected value** with the actual result rather than checking each property separately. This is the default in every language, not only Kotlin.

For example, in Kotlin prefer:

```kotlin
val expectedToken = PersonalAccessToken(
    userId = 1,
    name = "Test Token",
    tokenHash = "hash123",
    tokenPrefix = "abc1",
    createdAt = fixedCreatedAt,
    expiresAt = null,
    lastUsedAt = null,
)
assertEquals(expectedToken, token)
```

instead of one assertion per property.

Build an explicit, deterministic expected object in Arrange. Prefer fixing the clock, IDs, randomness, and other variable sources in the test so the entire returned object can be compared reliably.

Do not force whole-object equality when it is not appropriate. Use targeted assertions when:
- the type has no meaningful value-equality implementation (for example, a regular class with identity equality or an incomplete/custom `equals`);
- some fields are intentionally nondeterministic and are not part of the behavior being tested, and the source cannot reasonably be controlled;
- the test concerns a specific state transition, property, exception, side effect, or interaction rather than a returned value;
- whole-object comparison would hide the behavior under test or make the test misleading.

If only one or two fields represent the behavior under test and the rest are intentionally irrelevant, a focused assertion can be clearer than constructing a misleading full expected object. When whole-object comparison is inappropriate, keep targeted assertions minimal and explain the reason when it is not obvious.

For collections, compare the full expected collection when both contents and order are part of the contract. Use order-insensitive comparisons only when ordering is explicitly irrelevant.

Use the project's existing assertion library and style. Do not introduce a new dependency solely to compare objects.

## Review-fix tasks

For a review-fix task, the review comment is part of the acceptance criteria.

If the comment identifies an existing test file or test method:
- modify that existing test/scenario unless there is a concrete reason not to;
- do not create a parallel test that covers the same behavior merely because it is easier;
- preserve the existing test's intent while adding the requested assertions or setup.

If the comment contains a concrete production call, expected interaction, or assertion pattern, reproduce its intent in a real executable test. Do not replace a requested behavioral verification with structural assertions.

If the repository already has a suitable unit-test class for the production code, prefer adding the scenario there.

## What makes a good unit test

Test through the narrowest real production entry point that contains the behavior under test.

For a repository or service method:
- instantiate the system under test;
- mock external dependencies such as database, service, or network boundaries;
- invoke the public method under test;
- verify externally observable outcomes or dependency interactions.

Do not test a private helper directly when the behavior is reachable through the public method.

Do not mock the system under test itself.

For interaction-based behavior, use MockK `verify` (or the project's equivalent) on the actual dependency calls that matter. For example, when task removal must notify the owner and shares, execute `removeTask(...)` and verify the corresponding `fcmService.sendPushNotification(...)` calls.

Use exact arguments when they are part of the contract. Use `any()` only for values that are genuinely irrelevant to the behavior being tested.

## Mocking and difficult infrastructure

When the real production path uses a database transaction, ORM entity, singleton, static helper, or another difficult dependency:

- first inspect existing project test helpers and patterns;
- use the project's established mocking or test boundary when available;
- mock the dependency boundary, not random internal implementation details;
- keep the system-under-test path real.

A test-framework or mocking problem is not a reason to weaken the requested assertion.

Do not replace a real behavioral test with:
- constructor assertions;
- DTO or property assertions unrelated to the requested behavior;
- direct helper calls;
- a private-method test when a public entry point exists;
- a test that only proves `toDto()` or similar plumbing works.

If the intended behavioral test is temporarily blocked:
1. try a different mock boundary or existing project test pattern;
2. inspect analogous tests elsewhere in the repository;
3. determine whether a small production refactor is needed to make the behavior testable;
4. if a materially important design choice remains unresolved, stop with `TASK_NEEDS_USER` rather than silently lowering test quality.

## Test adequacy check

Before declaring the test complete, ask:

- Does the test execute the production path named or implied by the requirement?
- Would the test fail if the requested behavior were deleted?
- Does it verify the observable outcome, not just input setup?
- Could the returned value be checked with one whole-object/value equality assertion instead of many per-property assertions?
- If using per-property assertions, is whole-value equality unavailable, nondeterministic, or less expressive for this test?
- Does it cover the important actors or branches from the requirement?
- Did I accidentally create a duplicate scenario instead of extending an existing one?
- Did I weaken the test to make it pass after encountering mocking or build problems?

A test that passes while the requested behavior is removed is not an acceptable regression test.

## Verification

Run the most focused test first, then the relevant broader test suite when practical.

Report the exact commands actually run. Do not claim a test proves behavior that the test does not execute or assert.

## Whole-value assertion policy (global default)

Use `skills/unit-testing-language-agnostic/SKILL.md` as the source of truth for assertion style across languages. When the system under test returns a value object/model/DTO/entity or collection with reliable value equality and deterministic fields, assert the complete expected value instead of writing one assertion per property. In Kotlin this commonly means `assertEquals(expectedObject, actualObject)` for data classes.

Prefer to control clocks, IDs and other nondeterministic sources so full-value equality remains possible. Use field-level assertions only when equality is absent or misleading, the relevant field is intentionally variable and cannot reasonably be controlled, or the test concerns a specific property/state transition/exception/interaction rather than the whole returned value. Keep those assertions minimal. This applies to all languages; language-specific testing skills may add syntax but should not weaken this default.

