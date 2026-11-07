import pf.HeaderName
import pf.HeaderValue
import pf.Reply
import pf.Request
import pf.ResponseHeader
import pf.ResponseWriter

Sse := [].{
	## Where a stream's function sends its events, with `send!`. Valid only
	## inside that function.
	Writer :: ResponseWriter

	## How a stream behaves, for `reply_with`. Fields left out keep their
	## defaults.
	##
	## - `keep_alive`: a comment line (`:`) every 15 seconds without an
	##   event, so proxies keep the connection.
	## - `retry_milliseconds`: sent first, how long the client waits before
	##   it connects again (its own default when `None`).
	## - `ends_on_drain`: when the server stops, the stream ends at the
	##   function's next wait and the client connects again, to another
	##   worker.
	Options := {
		keep_alive : Sse.KeepAlive ?? Sse.KeepAlive.Every(15_000),
		retry_milliseconds : Sse.Retry ?? Sse.Retry.None,
		ends_on_drain : Bool ?? Bool.True,
	}

	## `Every(milliseconds)` writes a comment line each time `milliseconds`
	## pass without an event; `Off` writes nothing.
	KeepAlive := [Off, Every(U64)]

	## `Value(milliseconds)` sends a `retry` field before the first event.
	Retry := [None, Value(U64)]

	Event :: {
		data : Str,
		event_type : [None, Value(Str)],
		id : [None, Value(Str)],
		retry_milliseconds : [None, Value(U64)],
	}

	event : Str -> Event
	event = |data| Event.(
		{
			data,
			event_type: None,
			id: None,
			retry_milliseconds: None,
		},
	)

	with_event : Event, Str -> Try(Event, [InvalidEvent])
	with_event = |Event.(value), event_type|
		if has_line_break(event_type) {
			Err(InvalidEvent)
		} else {
			Ok(Event.({ ..value, event_type: Value(event_type) }))
		}

	with_id : Event, Str -> Try(Event, [InvalidId])
	with_id = |Event.(value), id|
		if has_line_break(id) or Str.contains(id, "\u(0)") {
			Err(InvalidId)
		} else {
			Ok(Event.({ ..value, id: Value(id) }))
		}

	with_retry : Event, U64 -> Event
	with_retry = |Event.(value), retry_milliseconds|
		Event.({ ..value, retry_milliseconds: Value(retry_milliseconds) })

	encode : Event -> List(U8)
	encode = |Event.(value)| {
		event_field = match value.event_type {
			None => ""
			Value(event_type) => "event: ${event_type}\n"
		}
		id_field = match value.id {
			None => ""
			Value(id) => "id: ${id}\n"
		}
		retry_field = match value.retry_milliseconds {
			None => ""
			Value(milliseconds) => "retry: ${milliseconds.to_str()}\n"
		}
		# A single data line needs no normalization, splitting, or line list.
		if !has_line_break(value.data) {
			return "${event_field}${id_field}${retry_field}data: ${value.data}\n\n".to_utf8()
		}
		normalized_crlf = Str.join_with(Str.split_on(value.data, "\r\n"), "\n")
		normalized = Str.join_with(Str.split_on(normalized_crlf, "\r"), "\n")
		data_fields = Str.split_on(normalized, "\n")
			|> List.map(|line| "data: ${line}\n")
			|> Str.join_with("")
		"${event_field}${id_field}${retry_field}${data_fields}\n".to_utf8()
	}

	## A `text/event-stream` reply whose events `send!` writes as `send_events!`
	## goes, with the default `Options`: a keep-alive comment every 15
	## seconds, and the stream ends when the server stops.
	##
	## ```roc
	## Sse.reply(|sse| {
	##     Sse.send!(sse, Sse.event("first"))?
	##     Sleep.millis!(1_000)
	##     Sse.send!(sse, Sse.event("second"))
	## })
	## ```
	reply : (Writer => Try({}, [StreamClosed])) -> Reply
	reply = |send_events!| Sse.reply_with(Options.{}, send_events!)

	## Like `reply`, with `options`:
	##
	## ```roc
	## Sse.reply_with(Sse.Options.{ retry_milliseconds: Sse.Retry.Value(3_000) }, send_ticks!)
	## ```
	reply_with : Options, (Writer => Try({}, [StreamClosed])) -> Reply
	reply_with = |options, send_events!| {
		keep_alive = match options.keep_alive {
			Sse.KeepAlive.Off => ResponseWriter.KeepAlive.None
			Sse.KeepAlive.Every(milliseconds) => ResponseWriter.KeepAlive.Every({ milliseconds, bytes: ":\n\n".to_utf8() })
		}
		writer_options = ResponseWriter.Options.{ keep_alive, ends_on_drain: options.ends_on_drain }
		retry = options.retry_milliseconds
		content_type : HeaderValue
		content_type = "text/event-stream"
		cache_control : HeaderValue
		cache_control = "no-cache"
		Reply.stream_with(
			writer_options,
			|writer| {
				match retry {
					Sse.Retry.None => {}
					Sse.Retry.Value(milliseconds) => ResponseWriter.write!(writer, "retry: ${milliseconds.to_str()}\n\n".to_utf8())?
				}
				send_events!(Writer.(writer))
			},
		)
			.with_headers(
				[
					ResponseHeader.{ name: HeaderName.("content-type"), value: content_type },
					ResponseHeader.{ name: HeaderName.("cache-control"), value: cache_control },
				],
			)
	}

	## Sends `event` whole. `Err(StreamClosed)` when the client is gone or did
	## not take it in time; the stream is then over.
	send! : Writer, Event => Try({}, [StreamClosed])
	send! = |Writer.(writer), message| ResponseWriter.write!(writer, Sse.encode(message))

	## A `text/event-stream` reply that sends `events` and ends.
	from_events : List(Event) -> Reply
	from_events = |events| Sse.reply(|sse| send_all!(sse, events))

	## The `Last-Event-ID` a client sends when it connects again: the `id` of
	## the last event it received, to go on after it. `Err(Missing)` on a first
	## connection, `Err(Invalid)` when the value is not UTF-8.
	last_event_id : Request -> Try(Str, [Missing, Invalid])
	last_event_id = |request|
		match List.find_first(request.headers, |header| HeaderName.inner(header.name) == "last-event-id") {
			Err(_) => Err(Missing)
			Ok(header) =>
				match Str.from_utf8(header.value) {
					Ok(value) => Ok(value)
					Err(_) => Err(Invalid)
				}
		}
}

send_all! : Sse.Writer, List(Sse.Event) => Try({}, [StreamClosed])
send_all! = |sse, events|
	match List.first(events) {
		Ok(first) => {
			Sse.send!(sse, first)?
			send_all!(sse, List.drop_first(events, 1))
		}
		Err(_) => Ok({})
	}

has_line_break : Str -> Bool
has_line_break = |value| Str.contains(value, "\r") or Str.contains(value, "\n")

expect Sse.encode(Sse.event("")) == "data: \n\n".to_utf8()
expect Sse.encode(Sse.event("one\r\ntwo\rthree\nfour")) == "data: one\ndata: two\ndata: three\ndata: four\n\n".to_utf8()
expect match Sse.with_event(Sse.event("data"), "update\nretry: 0") {
	Err(InvalidEvent) => Bool.True
	Ok(_) => Bool.False
}

expect match Sse.with_event(Sse.event("data"), "update\rretry: 0") {
	Err(InvalidEvent) => Bool.True
	Ok(_) => Bool.False
}

expect match Sse.with_id(Sse.event("data"), "one\r\ntwo") {
	Err(InvalidId) => Bool.True
	Ok(_) => Bool.False
}

expect match Sse.with_id(Sse.event("data"), "one\ntwo") {
	Err(InvalidId) => Bool.True
	Ok(_) => Bool.False
}

expect match Sse.with_id(Sse.event("data"), "one\u(0)two") {
	Err(InvalidId) => Bool.True
	Ok(_) => Bool.False
}

expect {
	match Sse.with_event(Sse.event("data"), "update") {
		Err(_) => Bool.False
		Ok(with_event) =>
			match Sse.with_id(with_event, "42") {
				Err(_) => Bool.False
				Ok(with_id) => {
					with_retry = Sse.with_retry(with_id, 0)
					Sse.encode(with_retry) == "event: update\nid: 42\nretry: 0\ndata: data\n\n".to_utf8()
				}
			}
		}
}

expect {
	maximum_retry : U64
	maximum_retry = 18446744073709551615
	Sse.encode(Sse.with_retry(Sse.event("data"), maximum_retry)) == "retry: 18446744073709551615\ndata: data\n\n".to_utf8()
}

# No separator, one separator, and adjacent separators cover empty lines;
# CRLF is one separator. UTF-8 and NUL are data, not line boundaries.
expect List.all(
	["", "a", "日本語", "a\u(0)b", "\r", "\n", "\r\n", "a\r", "a\n", "a\r\n", "\n\n", "\r\r", "\r\n\n"],
	|data| {
		normalized = Str.join_with(Str.split_on(Str.join_with(Str.split_on(data, "\r\n"), "\n"), "\r"), "\n")
		expected = Str.join_with(List.map(Str.split_on(normalized, "\n"), |line| "data: ${line}\n"), "")
		Sse.encode(Sse.event(data)) == "${expected}\n".to_utf8()
	},
)
