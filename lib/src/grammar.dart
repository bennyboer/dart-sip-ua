import 'package:parser_error/parser_error.dart';

import 'grammar_parser.dart';

class Grammar {
  static dynamic parse(String input, String startRule) {
    GrammarParser parser = GrammarParser('');
    dynamic result = parser.parse(input, startRule);
    if (!parser.success) {
      List<ParserErrorMessage> messages = [];
      for (GrammarParserError error in parser.errors()) {
        messages.add(
            ParserErrorMessage(error.message, error.start, error.position));
      }

      List<String> strings = ParserErrorFormatter.format(parser.text, messages);
      print(strings.join('\n'));
      throw FormatException();
    }
    return result;
  }
}
