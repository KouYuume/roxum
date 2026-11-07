import Reply
import RouteContext

## Internal record decoder for typed handlers.
RequestDecoder :: [].{

	## Reads the record `a` from the request, for `Handler.typed`.
	from_context : RouteContext(provided) -> Try(a, Reply)
		where [a.parser_for : RequestDecoder.Request -> (RequestDecoder.State(provided) -> Try({ value : a, rest : RequestDecoder.State(provided) }, [Rejected(Reply), ..errs]))]
	from_context = |context| {
		Shape : a
		parse_shape = Shape.parser_for(RequestDecoder.Request.Default)
		match parse_shape(RequestDecoder.State.{ context, index: 0, field: "", rejection: Reply.status(500) }) {
			Ok(parsed) => Ok(parsed.value)
			Err(Rejected(reply)) => Err(reply)
			Err(_) => Err(Reply.status(500))
		}
	}

	## How far reading the record has gone, and the reply of a field that failed
	## for the `Err` of a field typed `[Ok(_), Err(Reply)]`.
	State(provided) := { context : RouteContext(provided), index : U64, field : Str, rejection : Reply }.{
		rejection : RequestDecoder.State(provided) -> Reply
		rejection = |state| state.rejection
	}

	## The format that reads every field of the record from the request.
	Request := [Default].{

		## A field typed `[Ok(a), Err(Reply)]` reads `a`, and when that fails holds
		## what would have answered, so the handler runs and decides. Roc derives a
		## `Try` only as an optional field, so this is not `Try(a, Reply)`.
		parse_tag_union : RequestDecoder.Request, Encoding.ParseTagUnionSpec(a), RequestDecoder.State(provided) -> Try({ value : a, rest : RequestDecoder.State(provided) }, [Rejected(Reply)])
		parse_tag_union = |encoding, spec, state| {
			read_tag = |tag, current|
				Encoding.ParseTagUnionSpec.parse(
					spec,
					{
						tag,
						encoding,
						state: current,
						start_payloads: |payload_state, _| Ok(payload_state),
						next_payload: |payload_state, _, _| Ok(payload_state),
						finish_payloads: |payload_state, _| Ok(payload_state),
						missing: Rejected(Reply.status(500)),
					},
				)
			match read_tag("Ok", state) {
				Ok(parsed) => Ok(parsed)
				Err(Rejected(reply)) => read_tag("Err", { ..state, rejection: reply })
			}
		}

		rename_field : RequestDecoder.Request, Str -> Str
		rename_field = |_, name| name

		parse_record_start : RequestDecoder.Request, RequestDecoder.State(provided) -> Try([Counted({ len : U64, rest : RequestDecoder.State(provided) }), Uncounted(RequestDecoder.State(provided))], [Rejected(Reply)])
		parse_record_start = |_, state| Ok(Uncounted(state))

		parse_record_field : RequestDecoder.Request,
		Encoding.FieldName.FieldNames(_shape),
		RequestDecoder.State(provided) -> Try(
			[
				Field({ field : Encoding.FieldName(_shape), rest : RequestDecoder.State(provided) }),
				TryField({ name : Str, rest : RequestDecoder.State(provided) }),
				TryFieldCaseless({ name : Str, rest : RequestDecoder.State(provided) }),
				Continue(RequestDecoder.State(provided)),
				Done(RequestDecoder.State(provided)),
			],
			[Rejected(Reply)],
		)
		parse_record_field = |_, fields, state| {
			var $index = 0
			for field in fields.iter() {
				if $index == state.index {
					return Ok(Field({ field, rest: { ..state, index: state.index + 1, field: field.name() } }))
				}
				$index = $index + 1
			}
			Ok(Done(state))
		}

		parse_record_after_field : RequestDecoder.Request, RequestDecoder.State(provided) -> Try([Continue(RequestDecoder.State(provided)), Done(RequestDecoder.State(provided))], [Rejected(Reply)])
		parse_record_after_field = |_, state| Ok(Continue(state))

		skip_record_field : RequestDecoder.Request, RequestDecoder.State(provided) -> Try(RequestDecoder.State(provided), [Rejected(Reply)])
		skip_record_field = |_, state| Ok(state)
	}
}
