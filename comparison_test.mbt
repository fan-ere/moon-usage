///|
test "MoonBit compares late input repricing and signed reverse differences" {
  let initial = replay_input()
  let before = @moon-usage.capture(initial).unwrap()
  let late = {
    ..initial,
    input_revision: "events-2",
    events: [event("first", 11, 10), event("late", 12, 5)],
  }
  let after = @moon-usage.capture(late).unwrap()
  let change = @moon-usage.compare_snapshots(before, after).unwrap()
  assert_eq(change.quantity_delta, 5)
  assert_eq(change.total_minor_delta, 10L)
  assert_eq(change.added_event_ids, ["late"])
  assert_eq(change.plan_changed, false)
  let reverse = @moon-usage.compare_snapshots(after, before).unwrap()
  assert_eq(reverse.total_minor_delta, -10L)
  assert_eq(reverse.removed_event_ids, ["late"])
  let price = {
    ..late.plan,
    tiers: [{ up_to: Some(10), rate: 2, }, { up_to: None, rate: 1, }],
  }
  let repriced = @moon-usage.capture({
    ..late,
    plan_revision: "price-2",
    plan: price,
  }).unwrap()
  let change = @moon-usage.compare_snapshots(after, repriced).unwrap()
  assert_eq(change.total_minor_delta, -15L)
  assert_eq(change.plan_changed, true)
  assert_eq(object(change.to_json())["total_minor_delta"], Json("-15"))
}

///|
test "comparison refuses changed inputs and prices using stale revision labels" {
  let initial = replay_input()
  let before = @moon-usage.capture(initial).unwrap()
  let changed = @moon-usage.capture({
    ..initial,
    events: [event("changed", 11, 10)],
  }).unwrap()
  assert_eq(
    @moon-usage.compare_snapshots(before, changed).unwrap_err(),
    @moon-usage.ComparisonError::InputRevisionRequired,
  )
  let changed = @moon-usage.capture({
    ..initial,
    plan: { ..initial.plan, base_minor: 9, },
  }).unwrap()
  assert_eq(
    @moon-usage.compare_snapshots(before, changed).unwrap_err(),
    @moon-usage.ComparisonError::PlanRevisionRequired,
  )
}

///|
test "comparison rejects incompatible context and tracks corrected event content" {
  let initial = replay_input()
  let before = @moon-usage.capture(initial).unwrap()
  let changed = @moon-usage.capture({ ..initial, account: "other", }).unwrap()
  assert_eq(
    @moon-usage.compare_snapshots(before, changed).unwrap_err(),
    @moon-usage.ComparisonError::DifferentContext("account"),
  )
  let changed = @moon-usage.capture({
    ..initial,
    plan: { ..initial.plan, currency: "USD", },
  }).unwrap()
  assert_eq(
    @moon-usage.compare_snapshots(before, changed).unwrap_err(),
    @moon-usage.ComparisonError::DifferentContext("currency"),
  )
  let changed = @moon-usage.capture({
    ..initial,
    input_revision: "corrected",
    events: [event("first", 11, 8)],
  }).unwrap()
  let result = @moon-usage.compare_snapshots(before, changed).unwrap()
  assert_eq(result.changed_event_ids, ["first"])
  assert_eq(result.total_minor_delta, -6L)
}
