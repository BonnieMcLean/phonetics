require_relative '../phonetics'
require 'json'

module Phonetics
  class CodeGenerator

    attr_reader :writer

    def initialize(writer = STDOUT)
      @writer = writer
    end

    def generate_phonetic_cost_c_code
      PhoneticCost.new(writer).generate
    end

    def generate_next_phoneme_length_c_code
      NextPhonemeLength.new(writer).generate
    end

    private

    # Turn the bytes of all phonemes into a lookup trie where a sequence of
    # bytes can find a phoneme in linear time.
    def phoneme_byte_trie
      phoneme_byte_trie_for(Phonetics.phonemes)
    end

    def phoneme_byte_trie_for(phonemes)
      phonemes.reduce({}) do |trie, phoneme|
        phoneme.bytes.each_with_index.reduce(trie) do |subtrie, (byte, idx)|
          subtrie[byte] ||= {}

          # If we've reached the end of the byte string
          if phoneme.bytes.length - 1 == idx
            # Check if this is a duplicate lookup path. If there's a collision
            # then this whole approach makes no sense.
            if subtrie[byte].key?(:source)
              source = subtrie[byte][:source]
              raise "Duplicate byte sequence on #{phoneme.inspect} & #{source.inspect} (#{phoneme.bytes.inspect})"
            else
              subtrie[byte][:source] = phoneme
            end
          end
          subtrie[byte]
        end
        trie
      end
    end

    def ruby_source
      location = caller_locations.first
      "#{location.path.split('/')[-4..-1].join('/')}:#{location.lineno}"
    end

    def indent(depth, line)
      write "  #{'      ' * depth}#{line}"
    end

    def write(line)
      writer.puts line
    end

    def flush
      writer.flush
    end
  end

  class PhoneticCost < CodeGenerator
    # We find the phonetic distance between two phonemes using a compiled
    # lookup table. This is implemented as a set of nested switch statements.
    # Hard to read when compiled, but simple to generate and fast at runtime.
    #
    # We generate a `phonetic_cost` function that takes four arguments: Two
    # strings, and the lengths of those strings. Each string should be exactly
    # one valid phoneme, which is possible thanks to the (also generated)
    # next_phoneme_length() function.
    #
    # This will print a C code file with a function that implements a multil-level C
    # switch like the following:
    #
    #    if (phoneme1_length == 1) {
    #    switch (phoneme1[0]) {
    #      case 109: // only byte of "m"
    #        if (phoneme2_length == 1) {
    #           ...
    #        }
    #        ...
    #        if (phoneme2_length == 4) {
    #          switch (phoneme2[0]) {
    #            case 201: // first byte of "ɲ̊"
    #              if (phoneme2_length >= 2) {
    #                switch (phoneme2[1]) {
    #                  case 178: // second byte of "ɲ̊"
    #                    if (phoneme2_length >= 2) {
    #                      switch (phoneme2[2]) {
    #                        case 204: // third byte of "ɲ̊"
    #                          if (phoneme2_length >= 2) {
    #                            switch (phoneme2[3]) {
    #                              case 138: // fourth (and final) byte of "ɲ̊"
    #                                return (float) 0.4230;
    #                                break;
    #                            }
    #                          }
    #                          break;
    #                      }
    #                    }
    #                    break;
    #                }
    #              }
    #              break;
    #          }
    #        }
    #        break;
    #    }
    #
    #  the distance of ("m", "ɲ̊") is therefore 0.4230
    #
    def generate
      phonetic_cost_function

      by_byte_length.each do |length, phonemes|
        phonetic_cost_function_for_length(length, phonemes)
      end
    end

    def phonetic_cost_function
      write ''
      by_byte_length.each do |length, _|
        write "float phonetic_cost_length1_#{length}(int *string1, int pos1, int *string2, int pos2, int phoneme2_length);"
      end
      write(<<-HEADER.gsub(/^ {6}/, ''))

      // This is compiled from Ruby, in #{ruby_source}
      #include "./phonemes.h"
      float phonetic_cost(int *string1, int pos1, int string1_length, int *string2, int pos2, int string2_length) {
        int phoneme1_length;
        int phoneme2_length;

        if (pos1 >= string1_length) { return 1.0; };
        if (pos2 >= string2_length) { return 1.0; };

        phoneme1_length = next_phoneme_length(string1, pos1, string1_length);
        phoneme2_length = next_phoneme_length(string2, pos2, string2_length);

        if (phoneme1_length <= 0) { return 1.0; };
        if (phoneme2_length <= 0) { return 1.0; };

      HEADER

      write '  switch (phoneme1_length) {'
      by_byte_length.each do |length, _|
        write "   case #{length}:"
        write "     return phonetic_cost_length1_#{length}(string1, pos1, string2, pos2, phoneme2_length);"
        write '     break;'
      end
      write '    default:'
      write '      return (float) 1.0;'
      write '  }'
      write '};'
      write ''
    end

    def phonetic_cost_function_for_length(length, phonemes)
      write(<<-HEADER.gsub(/^ {6}/, ''))
      // This is compiled from Ruby, in #{ruby_source}
      float phonetic_cost_length1_#{length}(int *string1, int pos1, int *string2, int pos2, int phoneme2_length) {

      HEADER
      byte_trie = phoneme_byte_trie_for(phonemes)

      switch_phoneme1(byte_trie)

      write '  return 1.0;'
      write '};'
    end

    def switch_phoneme1(trie, depth = 0)
      indent depth, "  switch(string1[#{depth}]) {"
      write ''
      trie.each do |key, subtrie|
        next if key == :source
        next if subtrie.empty?

        indent depth, "    case #{key}:"

        phoneme1 = subtrie[:source]

        # Add a comment to help understand the dataset
        # describe(phoneme1, depth) if phoneme1

        # If this could be a match of a phoneme1 then find phoneme2
        if subtrie.keys == [:source]
          by_byte_length.each do |length, phonemes|
            byte_trie = phoneme_byte_trie_for(phonemes - [phoneme1])
            next if byte_trie.empty?

            indent depth, "      if (phoneme2_length == #{length}) {"
            switch_phoneme2(byte_trie, depth + 1, phoneme1)
            indent depth, '      }'
          end
        else
          switch_phoneme1(subtrie, depth + 1)
        end

        indent depth, "      break;"
      end
      indent depth, '    }'
    end

    def switch_phoneme2(trie, depth = 0, previous_phoneme)
      indent depth, "  switch(string1[#{depth}]) {"
      write ''
      trie.each do |key, subtrie|
        next if key == :source
        next if subtrie.empty?

        phoneme2 = subtrie[:source]

        # Add a comment to help understand the dataset
        # describe(phoneme2, depth) if phoneme2

        if subtrie.keys == [:source]
          value = distance(previous_phoneme, phoneme2)
          if value && value < 1.0
            indent depth, "    case #{key}:"
            indent depth, "      return (float) #{value};"
            indent depth, "      break;"
          end
        else
          indent depth, "    case #{key}:"
          switch_phoneme2(subtrie, depth + 1, previous_phoneme)
          indent depth, "      break;"
        end

      end
      indent depth, '    }'
    end

    def describe(phoneme, depth)
      indent depth, "      // Phoneme: #{phoneme.inspect}, bytes: #{phoneme.bytes.inspect}"
      if Phonetics::Consonants.features.key?(phoneme)
        indent depth, "      // consonant features: #{Phonetics::Consonants.features[phoneme].to_json}"
      else
        indent depth, "      // vowel features: #{Phonetics::Vowels::FormantFrequencies[phoneme].to_json}"
      end
    end

    def by_byte_length
      Phonetics.phonemes.group_by do |phoneme|
        phoneme.bytes.length
      end.sort_by(&:first).reverse
    end

    def distance(p1, p2)
      Phonetics.distance_map[p1][p2]
    end
  end

  class NextPhonemeLength < CodeGenerator
    # There's no simple way to break a string of IPA characters into phonemes.
    # We do it by generating a function that, given a string of IPA characters,
    # the starting index in that string, and the length of the string, returns
    # the length of the next phoneme, or zero if none is found.
    #
    # Pseudocode:
    #   - return 0 if length - index == 0
    #   - switch on first byte, matching on possible first bytes of phonemes
    #     within the selected case statement:
    #     - return 1 if length - index == 1
    #     - switch on second byte, matching on possible second bytes of phonemes
    #       within the selected case statement:
    #       - return 2 if length - index == 1
    #       ... 
    #       - default case: return 2 iff a phoneme terminates here
    #     - default case: return 1 iff a phoneme terminates here
    #   - return 0
    #
    def generate
      write(<<-HEADER.gsub(/^ {6}/, ''))
      // This is compiled from Ruby, in #{ruby_source}
      int next_phoneme_length(int *string, int cursor, int length) {

        int max_length;
        max_length = length - cursor;

      HEADER

      next_phoneme_switch(phoneme_byte_trie, 0)

      # If we fell through all the cases, return 0
      write '  return 0;'
      write '}'

      flush
    end

    private

    # Recursively build switch statements for the body of next_phoneme_length
    def next_phoneme_switch(trie, depth)
      # switch (string[cursor + depth]) {
      #   case N: // for N in subtrie.keys
      #     // if a case statement matches the current byte AND there's chance
      #     // that a longer string might match, recurse.
      #     if (max_length >= depth) {
      #       // recurse
      #     }
      #     break;
      #   // if there's a :source key here then a phoneme terminates at this
      #   // point and this depth is a valid return value.
      #   default:
      #     return depth;
      #     break;
      # }
      indent depth, "switch(string[cursor + #{depth}]) {"
      write ''
      trie.each do |key, subtrie|
        next if key == :source
        next if subtrie.empty?

        indent depth, "  case #{key}:"

        # Add a comment to help understand the dataset
        if subtrie[:source]
          phoneme = subtrie[:source]
          indent depth, "    // Phoneme: #{phoneme.inspect}, bytes: #{phoneme.bytes.inspect}"
          if Phonetics::Consonants.features.key?(phoneme)
            indent depth, "    // consonant features: #{Phonetics::Consonants.features[phoneme].to_json}"
          else
            indent depth, "    // vowel features: #{Phonetics::Vowels::FormantFrequencies[phoneme].to_json}"
          end
        end

        if subtrie.keys == [:source]
          indent depth, "    return #{depth+1};"
        else
          indent depth, "    if (max_length > #{depth + 1}) {"
          next_phoneme_switch(subtrie, depth + 1)
          indent depth, "    }"
        end

        indent depth, "    break;"
      end

      if trie.key?(:source)
        indent depth, "  default:"
        indent depth, "    return #{depth};"
      end
      indent depth, "}"
    end
  end
end
