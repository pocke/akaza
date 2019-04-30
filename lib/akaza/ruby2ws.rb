module Akaza
  # Convert Ruby like script to Whitespace.
  # The syntax is a subset of Ruby,
  # but it has different semantics with Ruby.
  #
  # # sample code
  #   # output
  #   put_as_number n
  #   put_as_char ch
  #   puts "Hello, world!"
  #
  #   # input
  #   num = get_as_number
  #   char = get_as_char
  #
  #   # flow
  #   def foo
  #   end
  #   exit
  #   if x == 0
  #   end
  #   if x < 0
  #   end
  #
  #   # heap
  #   x = 10
  #   push x
  #
  #   # stack
  #   push 1
  #   dup
  #   swap
  #   pop
  module Ruby2ws
    using AstExt
    SPACE = ' '
    TAB = "\t"
    NL = "\n"

    class ParseError < StandardError; end

    def self.ruby_to_ws(ruby_code)
      Transpiler.new(ruby_code).compile
    end

    class Transpiler
      def initialize(ruby_code)
        @ruby_code = ruby_code
      end

      def transpile
        commands = ruby_to_commands
        commands_to_ws(commands)
      end

      def ruby_to_commands
        ast = RubyVM::AbstractSyntaxTree.parse(@ruby_code)
        commands = []
        methods = {}
        current_commands = commands

        on_exit = -> (node) do
          if node.type == :DEFN
            current_commands = commands
          end
        end

        ast.traverse(on_exit: on_exit) do |node, opt|
          case node
          in [:FCALL, :put_as_number, [:ARRAY, [:LVAR, var], nil]]
            current_commands << [:stack, :push, str_to_int(var, type: :variable)]
            current_commands << [:heap, :load]
            current_commands << [:io, :write_num]
            opt[:skip_children] = true
          in [:FCALL, :put_as_char, [:ARRAY, [:LVAR, var], nil]]
            current_commands << [:stack, :push, str_to_int(var, type: :variable)]
            current_commands << [:heap, :load]
            current_commands << [:io, :write_char]
            opt[:skip_children] = true
          in [:LASGN, var, [:LIT, num]]
            current_commands << [:stack, :push, str_to_int(var, type: :variable)]
            current_commands << [:stack, :push, num]
            current_commands << [:heap, :save]
            opt[:skip_children] = true
          in [:LASGN, var, [:STR, str]]
            raise ParserError, "String size must be 1, but it's #{str} (#{str.size})" if str.size != 1

            current_commands << [:stack, :push, str_to_int(var, type: :variable)]
            current_commands << [:stack, :push, str.ord]
            current_commands << [:heap, :save]
            opt[:skip_children] = true
          in [:SCOPE, *_]
            # skip
          in [:BLOCK, *_]
            # skip
          end
        end

        commands.concat(*methods.values)
        commands + [[:flow, :exit]]
      end

      def commands_to_ws(commands)
        buf = +""
        commands.each do |command|
          case command
          in [:stack, :push, num]
            buf << SPACE << SPACE << num_to_ws(num)
          in [:heap, :save]
            buf << TAB << TAB << SPACE
          in [:heap, :load]
            buf << TAB << TAB << TAB
          in [:io, :write_char]
            buf << TAB << NL << SPACE << SPACE
          in [:io, :write_num]
            buf << TAB << NL << SPACE << TAB
          in [:flow, :exit]
            buf << NL << NL << NL
          end
        end
        buf
      end

      private def str_to_int(str, type:)
        prefix =
          case type
          when :variable then 'var'
          when :method   then 'func'
          else
            raise "Unknown type: #{type}"
          end
        "#{prefix}_#{str}".bytes.inject { |a, b| (a << 8) + b }
      end

      private def num_to_ws(num)
        sign =
          if num < 0
            TAB
          else
            SPACE
          end
        sign + num.abs.to_s(2).gsub("1", TAB).gsub('0', SPACE) + NL
      end
    end
  end
end
