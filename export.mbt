///|
/// Stable JSON envelope. Int64 money values are decimal strings for exact JS interchange.
/// This serializes the supplied value; it does not authenticate or revalidate a Bill.
pub fn Bill::to_json(self : Bill) -> Json {
  let (aggregation, reset_policy) = match self.usage.aggregation {
    Sum => ("sum", Json::null())
    Peak => ("peak", Json::null())
    Last => ("last", Json::null())
    Counter(RejectDecrease) => ("counter", Json("reject_decrease"))
    Counter(RestartAtZero) => ("counter", Json("restart_at_zero"))
  }
  let lines = self.quote.lines.map(fn(line) {
    Json({
      "tier": Json(line.tier),
      "quantity": Json(line.quantity),
      "rate": Json(line.rate),
      "numerator": Json(line.numerator.to_string()),
    })
  })
  let deltas = self.usage.counter_deltas.map(fn(d) {
    Json({
      "event_id": Json(d.event_id),
      "time": Json(d.time),
      "previous": Json(d.previous),
      "reading": Json(d.reading),
      "delta": Json(d.delta),
      "reset": Json(d.reset),
    })
  })
  Json({
    "schema": Json("moon-usage.bill.v1"),
    "account": Json(self.account),
    "meter": Json(self.meter),
    "start": Json(self.start),
    "end": Json(self.end),
    "usage": Json({
      "aggregation": Json(aggregation),
      "reset_policy": reset_policy,
      "quantity": Json(self.usage.quantity),
      "accepted_events": Json(self.usage.accepted_events),
      "duplicate_events": Json(self.usage.duplicate_events),
      "reset_events": Json(self.usage.reset_events),
      "baseline_id": match self.usage.baseline_id {
        Some(id) => Json(id)
        None => Json::null()
      },
      "event_ids": Json(self.usage.event_ids.map(fn(id) { Json(id) })),
      "counter_deltas": Json(deltas),
    }),
    "quote": Json({
      "currency": Json(self.quote.currency),
      "pricing": Json(
        match self.quote.pricing {
          Graduated => "graduated"
          Volume => "volume"
        },
      ),
      "rounding": Json(
        match self.quote.rounding {
          Down => "down"
          Up => "up"
          HalfEven => "half_even"
        },
      ),
      "quantity": Json(self.quote.quantity),
      "denominator": Json(self.quote.denominator),
      "lines": Json(lines),
      "usage_numerator": Json(self.quote.usage_numerator.to_string()),
      "usage_minor": Json(self.quote.usage_minor.to_string()),
      "base_minor": Json(self.quote.base_minor),
      "total_minor": Json(self.quote.total_minor.to_string()),
    }),
  })
}
