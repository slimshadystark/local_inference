/// The example's two toy tools: the time on the device, and unit conversion.
library;

import 'package:local_inference_flutter/local_inference_flutter.dart';

/// Units [convertUnits] knows, by kind; a conversion stays within one kind.
const unitKinds = {
  'celsius': 'temperature',
  'fahrenheit': 'temperature',
  'kilometers': 'length',
  'miles': 'length',
  'kilograms': 'mass',
  'pounds': 'mass',
};

/// [value] in [from], converted to [to]; null when the units are of different kinds.
double? convertUnits(double value, String from, String to) {
  if (unitKinds[from] == null || unitKinds[from] != unitKinds[to]) return null;
  if (from == to) return value;
  return switch ((from, to)) {
    ('celsius', 'fahrenheit') => value * 9 / 5 + 32,
    ('fahrenheit', 'celsius') => (value - 32) * 5 / 9,
    ('kilometers', 'miles') => value / 1.609344,
    ('miles', 'kilometers') => value * 1.609344,
    ('kilograms', 'pounds') => value / 0.45359237,
    ('pounds', 'kilograms') => value * 0.45359237,
    _ => null,
  };
}

/// The assistant: a short system prompt and the two tools. The model writes the replies from the tool results
/// (`ModelWrittenReplies`, the default of [AssistantConfig.basic]). [now] is the clock of `get_time`.
AssistantConfig chatConfig({DateTime Function() now = DateTime.now}) => AssistantConfig.basic(
  systemPrompt:
      'You are a helpful assistant in a demo app. Answer briefly. Use the tools for the current time and for unit '
      'conversions.',
  tools: [_time(now), _convert],
);

AssistantTool _time(DateTime Function() now) => AssistantTool(
  name: 'get_time',
  description: 'The current date, time and weekday on this device.',
  statusLabel: 'Reading the clock...',
  run: (call, context) {
    final t = now();
    String two(int n) => n.toString().padLeft(2, '0');
    return ToolResult.ok({
      'date': '${t.year}-${two(t.month)}-${two(t.day)}',
      'time': '${two(t.hour)}:${two(t.minute)}',
      'weekday': const ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'][t.weekday - 1],
    });
  },
);

final AssistantTool _convert = AssistantTool(
  name: 'convert_units',
  description: 'Converts a value between units of temperature, length or mass.',
  parameters: ToolSchema.object(
    {
      'value': ToolSchema.number(description: 'The value to convert.'),
      'from': ToolSchema.string(description: 'The unit of the value.', enumValues: unitKinds.keys.toList()),
      'to': ToolSchema.string(description: 'The unit to convert to.', enumValues: unitKinds.keys.toList()),
    },
    required: ['value', 'from', 'to'],
  ),
  statusLabel: 'Converting...',
  // The assistant checks each call against the schema above before run: a call with a missing argument, a value that
  // is not a number or a unit not in the list gets invalid_arguments and never runs. So the arguments are typed here.
  run: (call, context) {
    final value = (call.arguments['value']! as num).toDouble();
    final from = call.requireString('from'), to = call.requireString('to');
    final result = convertUnits(value, from, to);
    if (result == null) return ToolResult.error('cannot_convert', 'cannot convert $from to $to');
    return ToolResult.ok({'value': value, 'from': from, 'to': to, 'result': double.parse(result.toStringAsFixed(2))});
  },
);
