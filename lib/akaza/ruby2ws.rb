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
        ast = RubyVM::AbstractSyntaxTree.parse(@ruby_code)
        commands = ast_to_commands(ast, method: false)
        commands_to_ws(commands)
      end

      private def ast_to_commands(ast, method:)
        commands = []
        methods = []
        lvars = []

        ast.traverse do |node, opt|
          case node
          in [:FCALL, :put_as_number, [:ARRAY, arg, nil]]
            commands.concat(push_value(arg))
            commands << [:io, :write_num]
            opt[:skip_children] = true
          in [:FCALL, :put_as_char, [:ARRAY, arg, nil]]
            commands.concat(push_value(arg))
            commands << [:io, :write_char]
            opt[:skip_children] = true
          in [:LASGN, var, arg]
            var_addr = str_to_int(var, type: :variable)
            commands << [:stack, :push, var_addr]
            commands.concat(push_value(arg))
            commands << [:heap, :save]
            opt[:skip_children] = true
            lvars << var_addr
          in [:DEFN, name, [:SCOPE, _, _, body]]
            methods << [
              [:flow, :def, str_to_int(name, type: :method)],
              *ast_to_commands(body, method: true),
              [:flow, :end],
            ]
            opt[:skip_children] = true
          in [:SCOPE, *_]
            # skip
          in [:BLOCK, *_]
            # skip
          in [:VCALL, name]
            with_storing_lvars(lvars, commands) do
              commands << [:flow, :call, str_to_int(name, type: :method)]
            end
            opt[:skip_children] = true
          in [:FCALL, name, [:ARRAY, *args, nil]]
            with_storing_lvars(lvars, commands) do
              args.each do |arg|
                push_value(arg)
              end
              commands << [:flow, :call, str_to_int(name, type: :method)]
            end
            opt[:skip_children] = true
          end
        end

        commands += [[:flow, :exit]] unless method
        commands.concat(*methods)
        commands
      end

      private def commands_to_ws(commands)
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

      private def with_storing_lvars(lvars, commands, &block)
        lvars.each do |var_addr|
          # stack.push(addr); stack.push(val)
          commands << [:stack, :push, var_addr]
          commands << [:stack, :push, var_addr]
          commands << [:heap, :load]
          # Fill zero
          commands << [:stack, :push, var_addr]
          commands << [:stack, :push, 0]
          commands << [:heap, :save]
        end

        block.call

        lvars.size.times do
          commands << [:heap, :save]
        end
      end

      private def push_value(ast)
        commands = []

        case ast
        in [:LIT, num]
          commands << [:stack, :push, num]
        in [:STR, str]
          check_char!(str)
          commands << [:stack, :push, str.ord]
        in [:LVAR, name]
          commands << [:stack, :push, str_to_int(name, type: :variable)]
          commands << [:heap, :load]
        end

        commands
      end

      private def check_char!(char)
        raise ParserError, "String size must be 1, but it's #{char} (#{char.size})" if char.size != 1
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
