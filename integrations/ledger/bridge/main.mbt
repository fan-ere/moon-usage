///|
// Node supplies transport only; all validation and billing remain in MoonBit.
extern "js" fn read_stdin() -> String =
  #| () => require("node:fs").readFileSync(0, "utf8")

///|
fn fail(message : String) -> Json {
  Json({ "ok": Json(false), "error": Json(message) })
}

///|
fn handle(request : Json) -> Json {
  guard request is Object(fields) else {
    return fail("Expected request object")
  }
  guard fields.get("command") is Some(String(command)) else {
    return fail("Missing command")
  }
  guard fields.get("payload") is Some(String(payload)) else {
    return fail("Missing payload text")
  }
  if command == "compare" {
    let value = @json.parse(
      payload,
      reject_duplicate_keys=true,
      max_nesting_depth=64,
    ) catch {
      error => return fail(error.to_string())
    }
    guard value is Object(pair) && pair.length() == 2 else {
      return fail("Expected before and after snapshot texts")
    }
    guard pair.get("before") is Some(String(old_text)) &&
      pair.get("after") is Some(String(new_text)) else {
      return fail("Expected before and after snapshot texts")
    }
    let before = match @usage.Snapshot::from_string(old_text) {
      Ok(value) => value
      Err(error) => return fail(error.to_repr().to_string())
    }
    let after = match @usage.Snapshot::from_string(new_text) {
      Ok(value) => value
      Err(error) => return fail(error.to_repr().to_string())
    }
    return match @usage.compare_snapshots(before, after) {
      Ok(change) => Json({ "ok": Json(true), "change": change.to_json() })
      Err(error) => fail(error.to_repr().to_string())
    }
  }
  let result = match command {
    "capture" => {
      let input = match @usage.BillInput::from_string(payload) {
        Ok(i) => i
        Err(e) => return fail(e.to_repr().to_string())
      }
      @usage.capture(input)
    }
    "verify" => @usage.Snapshot::from_string(payload)
    _ => return fail("Unknown command")
  }
  match result {
    Ok(snapshot) => Json({ "ok": Json(true), "snapshot": snapshot.to_json() })
    Err(e) => fail(e.to_repr().to_string())
  }
}

///|
fn main {
  let request = @json.parse(
    read_stdin(),
    reject_duplicate_keys=true,
    max_nesting_depth=64,
  ) catch {
    e => {
      println(fail(e.to_string()).stringify())
      return
    }
  }
  println(handle(request).stringify())
}
