///|
pub(all) struct BillRequest {
  id : String
  account : String
  meter : String
  start : Int32
  end : Int32
  aggregation : Aggregation
  plan_revision : String
  plan : Plan
}

///|
pub(all) struct NamedSnapshot {
  id : String
  snapshot : Snapshot
}

///|
pub(all) struct CurrencyTotal {
  currency : String
  total_minor : Int64
} derive(Eq, Debug)

///|
pub extend CurrencyTotal with Eq::{equal, not_equal}

///|
pub extend CurrencyTotal with @debug.Debug::{to_repr}

///|
pub(all) struct BatchBill {
  bills : Array[NamedSnapshot]
  totals : Array[CurrencyTotal]
}

///|
pub(all) enum BatchError {
  InvalidRequestCount
  EmptyRequestId
  DuplicateRequest(String)
  DuplicateContext(String)
  CalculationFailed(String, ReplayError)
  TotalOverflow(String)
  OutputLimit
} derive(Eq, Debug)

///|
pub extend BatchError with Eq::{equal, not_equal}

///|
pub extend BatchError with @debug.Debug::{to_repr}

///|
/// All-or-error batch result, not a database transaction or settlement operation.
/// Requests must cover distinct account/meter/period contexts; totals never mix currencies.
pub fn capture_batch(
  events : Array[Event],
  input_revision : String,
  requests : Array[BillRequest],
) -> Result[BatchBill, BatchError] {
  if requests.is_empty() || requests.length() > 256 {
    return Err(InvalidRequestCount)
  }
  let ids : Map[String, Bool] = Map([])
  for i, request in requests {
    if request.id == "" {
      return Err(EmptyRequestId)
    }
    if ids.contains(request.id) {
      return Err(DuplicateRequest(request.id))
    }
    ids[request.id] = true
    for j in 0..<i {
      let previous = requests[j]
      if previous.account == request.account &&
        previous.meter == request.meter &&
        previous.start == request.start &&
        previous.end == request.end {
        return Err(DuplicateContext(request.id))
      }
    }
  }
  let bills : Array[NamedSnapshot] = []
  let amounts : Map[String, Int64] = Map([])
  let mut size = 0
  for request in requests {
    let snapshot = match
      capture({
        events,
        input_revision,
        plan_revision: request.plan_revision,
        account: request.account,
        meter: request.meter,
        start: request.start,
        end: request.end,
        aggregation: request.aggregation,
        plan: request.plan,
      }) {
      Ok(value) => value
      Err(error) => return Err(CalculationFailed(request.id, error))
    }
    let length = snapshot.to_string().length()
    if length > 16777216 - size {
      return Err(OutputLimit)
    }
    size += length
    let bill = match snapshot.replay() {
      Ok(value) => value
      Err(error) => return Err(CalculationFailed(request.id, error))
    }
    let currency = bill.quote.currency
    let current = amounts.get(currency).unwrap_or(0L)
    let amount = bill.quote.total_minor
    if amount > 9223372036854775807L - current {
      return Err(TotalOverflow(currency))
    }
    amounts[currency] = current + amount
    bills.push({ id: request.id, snapshot, })
  }
  let currencies = amounts.keys().to_array()
  currencies.sort()
  let totals = currencies.map(fn(currency) {
    { currency, total_minor: amounts[currency], }
  })
  Ok({ bills, totals, })
}
