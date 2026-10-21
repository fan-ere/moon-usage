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
  let result = match command {
    "capture" => {
      let value = @json.parse(
        payload,
        reject_duplicate_keys=true,
        preserve_number_repr=true,
        max_nesting_depth=64,
      ) catch {
        e => return fail(e.to_string())
      }
      let input = match @usage.BillInput::from_json(value) {
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
