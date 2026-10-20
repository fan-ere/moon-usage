///|
/// A timestamp is a caller-defined nonnegative integer tick; all inputs use one scale.
pub(all) struct Event {
  id : String
  account : String
  meter : String
  time : Int
  value : Int
} derive(Eq, Debug)

///|
pub(all) enum Aggregation {
  Sum
  Peak
  Last
  Counter(ResetPolicy)
} derive(Eq, Debug)

///|
pub(all) enum ResetPolicy {
  RejectDecrease
  RestartAtZero
} derive(Eq, Debug)

///|
pub(all) enum Rounding {
  Down
  Up
  HalfEven
} derive(Eq, Debug)

///|
pub(all) enum Pricing {
  Graduated
  Volume
} derive(Eq, Debug)

///|
/// Cumulative upper bounds are inclusive: quantity intervals are (previous, up_to].
/// The last tier must have up_to=None, including for zero usage.
pub(all) struct Tier {
  up_to : Int?
  rate : Int
} derive(Eq, Debug)

///|
/// Rate is minor currency units per `per_units` meter units.
pub(all) struct Plan {
  currency : String
  pricing : Pricing
  tiers : Array[Tier]
  per_units : Int
  base_minor : Int
  rounding : Rounding
} derive(Debug)

///|
pub(all) enum UsageError {
  InvalidPeriod
  EmptyIdentity
  InvalidValue(String)
  DuplicateConflict(String)
  AmbiguousReading(Int)
  MissingBaseline
  CounterDecreased(String)
  QuantityLimit
  InvalidPlan(String)
} derive(Eq, Debug)

///|
pub(all) struct Usage {
  aggregation : Aggregation
  quantity : Int
  accepted_events : Int
  duplicate_events : Int
  reset_events : Int
  baseline_id : String?
  event_ids : Array[String]
  counter_deltas : Array[CounterDelta]
} derive(Debug)

///|
/// One cumulative reading and its attributed increment, including explicit resets.
pub(all) struct CounterDelta {
  event_id : String
  time : Int
  previous : Int
  reading : Int
  delta : Int
  reset : Bool
} derive(Eq, Debug)

///|
pub extend CounterDelta with Eq::{equal, not_equal}

///|
pub extend CounterDelta with @debug.Debug::{to_repr}

///|
/// Exact fractional charge is numerator / denominator; rounding occurs once per quote.
pub(all) struct ChargeLine {
  tier : Int
  quantity : Int
  rate : Int
  numerator : Int64
} derive(Eq, Debug)

///|
pub(all) struct Quote {
  currency : String
  pricing : Pricing
  rounding : Rounding
  quantity : Int
  denominator : Int
  lines : Array[ChargeLine]
  usage_numerator : Int64
  usage_minor : Int64
  base_minor : Int
  total_minor : Int64
} derive(Debug)

///|
pub(all) struct Bill {
  account : String
  meter : String
  start : Int
  end : Int
  usage : Usage
  quote : Quote
} derive(Debug)

///|
pub extend Event with Eq::{equal, not_equal}

///|
pub extend Aggregation with Eq::{equal, not_equal}

///|
pub extend ResetPolicy with Eq::{equal, not_equal}

///|
pub extend Rounding with Eq::{equal, not_equal}

///|
pub extend Pricing with Eq::{equal, not_equal}

///|
pub extend Tier with Eq::{equal, not_equal}

///|
pub extend UsageError with Eq::{equal, not_equal}

///|
pub extend ChargeLine with Eq::{equal, not_equal}

///|
pub extend Event with @debug.Debug::{to_repr}

///|
pub extend Aggregation with @debug.Debug::{to_repr}

///|
pub extend ResetPolicy with @debug.Debug::{to_repr}

///|
pub extend Rounding with @debug.Debug::{to_repr}

///|
pub extend Pricing with @debug.Debug::{to_repr}

///|
pub extend Tier with @debug.Debug::{to_repr}

///|
pub extend Plan with @debug.Debug::{to_repr}

///|
pub extend UsageError with @debug.Debug::{to_repr}

///|
pub extend Usage with @debug.Debug::{to_repr}

///|
pub extend ChargeLine with @debug.Debug::{to_repr}

///|
pub extend Quote with @debug.Debug::{to_repr}

///|
pub extend Bill with @debug.Debug::{to_repr}
