///|
/// Check all tiers, including tiers not reached by this quote.
pub fn validate_plan(plan : Plan) -> Result[Unit, UsageError] {
  if plan.currency == "" {
    return Err(InvalidPlan("empty currency"))
  }
  if plan.per_units <= 0 || plan.per_units > 1000000000 {
    return Err(InvalidPlan("per_units must be 1..1000000000"))
  }
  if plan.base_minor < 0 || plan.base_minor > 1000000000 {
    return Err(InvalidPlan("base_minor must be 0..1000000000"))
  }
  if plan.tiers.is_empty() {
    return Err(InvalidPlan("no tiers"))
  }
  let mut previous = 0
  for i, tier in plan.tiers {
    if tier.rate < 0 || tier.rate > 1000000000 {
      return Err(InvalidPlan("rate must be 0..1000000000"))
    }
    match tier.up_to {
      Some(bound) => {
        if bound <= previous || bound > 1000000000 {
          return Err(
            InvalidPlan("tier bounds must increase within 1..1000000000"),
          )
        }
        if i == plan.tiers.length() - 1 {
          return Err(InvalidPlan("last tier must be unbounded"))
        }
        previous = bound
      }
      None =>
        if i != plan.tiers.length() - 1 {
          return Err(InvalidPlan("only last tier may be unbounded"))
        }
    }
  }
  Ok(())
}

///|
fn rounded(numerator : Int64, denominator : Int, mode : Rounding) -> Int64 {
  let d = denominator.to_int64()
  let whole = numerator / d
  let remainder = numerator % d
  let increment = match mode {
    Down => false
    Up => remainder > 0L
    HalfEven => remainder * 2L > d || (remainder * 2L == d && whole % 2L == 1L)
  }
  if increment {
    whole + 1L
  } else {
    whole
  }
}

///|
/// Pure rating; quantities and rates are bounded so all intermediates fit Int64.
pub fn rate(plan : Plan, quantity : Int) -> Result[Quote, UsageError] {
  match validate_plan(plan) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  if quantity < 0 || quantity > 1000000000 {
    return Err(QuantityLimit)
  }
  let lines : Array[ChargeLine] = []
  let mut numerator = 0L
  let mut previous = 0
  for i, tier in plan.tiers {
    let upper = match tier.up_to {
      Some(n) => n
      None => 1000000000
    }
    match plan.pricing {
      Graduated => {
        let used = if quantity < upper { quantity } else { upper }
        if used > previous {
          let units = used - previous
          let part = units.to_int64() * tier.rate.to_int64()
          lines.push({
            tier: i,
            quantity: units,
            rate: tier.rate,
            numerator: part,
          })
          numerator += part
        }
        if quantity <= upper {
          break
        }
      }
      Volume =>
        if quantity <= upper {
          numerator = quantity.to_int64() * tier.rate.to_int64()
          lines.push({ tier: i, quantity, rate: tier.rate, numerator, })
          break
        }
    }
    previous = upper
  }
  let usage_minor = rounded(numerator, plan.per_units, plan.rounding)
  Ok({
    currency: plan.currency,
    pricing: plan.pricing,
    rounding: plan.rounding,
    quantity,
    denominator: plan.per_units,
    lines,
    usage_numerator: numerator,
    usage_minor,
    base_minor: plan.base_minor,
    total_minor: usage_minor + plan.base_minor.to_int64(),
  })
}

///|
/// End-to-end replay from a complete batch. This function does not persist dedup state.
pub fn bill(
  events : Array[Event],
  account : String,
  meter : String,
  start : Int,
  end : Int,
  mode : Aggregation,
  plan : Plan,
) -> Result[Bill, UsageError] {
  let usage = match aggregate(events, account, meter, start, end, mode) {
    Ok(value) => value
    Err(e) => return Err(e)
  }
  let quote = match rate(plan, usage.quantity) {
    Ok(value) => value
    Err(e) => return Err(e)
  }
  Ok({ account, meter, start, end, usage, quote, })
}
