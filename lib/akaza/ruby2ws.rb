module Akaza
  # Convert Ruby like script to Whitespace.
  # The syntax is a subset of Ruby,
  # but it has different semantics with Ruby.
  #
  # # sample code
  #   # output
  #   put_as_number n
  #   put_as_char ch
  #   put_as_number 42
  #   put_as_char 'a'
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
  #
  #   # inline
  #   inline "   "
  #   inline {   }
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
        commands = ast_to_commands
        commands_to_ws(commands)
      end

      def ast_to_commands(ast = RubyVM::AbstractSyntaxTree.parse(@ruby_code))
        commands = []
        methods = []

        ast.traverse do |node, opt|
          case node
          in [:FCALL, :put_as_number, [:ARRAY, [:LVAR, var], nil]]
            commands << [:stack, :push, str_to_int(var, type: :variable)]
            commands << [:heap, :load]
            commands << [:io, :write_num]
            opt[:skip_children] = true
          in [:FCALL, :put_as_number, [:ARRAY, [:LIT, num], nil]]
            commands << [:stack, :push, num]
            commands << [:io, :write_num]
            opt[:skip_children] = true
          in [:FCALL, :put_as_char, [:ARRAY, [:LVAR, var], nil]]
            commands << [:stack, :push, str_to_int(var, type: :variable)]
            commands << [:heap, :load]
            commands << [:io, :write_char]
            opt[:skip_children] = true
          in [:FCALL, :put_as_char, [:ARRAY, [:STR, str], nil]]
            raise ParserError, "String size must be 1, but it's #{str} (#{str.size})" if str.size != 1

            commands << [:stack, :push, str.ord]
            commands << [:io, :write_char]
            opt[:skip_children] = true
          in [:LASGN, var, [:LIT, num]]
            commands << [:stack, :push, str_to_int(var, type: :variable)]
            commands << [:stack, :push, num]
            commands << [:heap, :save]
            opt[:skip_children] = true
          in [:LASGN, var, [:STR, str]]
            raise ParserError, "String size must be 1, but it's #{str} (#{str.size})" if str.size != 1

            commands << [:stack, :push, str_to_int(var, type: :variable)]
            commands << [:stack, :push, str.ord]
            commands << [:heap, :save]
            opt[:skip_children] = true
          in [:DEFN, name, [:SCOPE, _, _, body]]
            methods << [
              [:flow, :def, str_to_int(name, type: :method)],
              *ast_to_commands(body),
              [:flow, :end],
            ]
            opt[:skip_children] = true
          in [:SCOPE, *_]
            # skip
          in [:BLOCK, *_]
            # skip
          in [:VCALL, name]
            commands << [:flow, :call, str_to_int(name, type: :method)]
            opt[:skip_children] = true
          end
        end

        commands.concat(*methods)
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
          in [:flow, :call, num]
            buf << NL << SPACE << TAB << num_to_ws(num)
          in [:flow, :def, num]
            buf << NL << SPACE << SPACE << num_to_ws(num)
          in [:flow, :end]
            buf << NL << TAB << NL
          end
        end
        buf
      end

      private def str_to_int(str, type:)
        prefix =
          case type
          when :variable then 'v'
          when :method   then 'f'
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
