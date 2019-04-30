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
  #
  #   # input
  #   num = get_as_number
  #   char = get_as_char
  #
  #   # flow
  #   def foo
  #   end
  #
  #   exit
  #
  #   if x == 0
  #   end
  #
  #   if x < 0
  #   end
  #
  #   # heap
  #   x = 10
  #   push x
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
        @label_index = 0
      end

      def transpile
        ast = RubyVM::AbstractSyntaxTree.parse(@ruby_code)
        commands = ast_to_commands(ast, main: true)
        commands_to_ws(commands)
      end

      private def ast_to_commands(ast, main:)
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
          in [:VCALL, :exit]
            commands << [:flow, :exit]
          in [:LASGN, var, arg]
            var_addr = str_to_int(var, type: :variable)
            commands << [:stack, :push, var_addr]
            commands.concat(push_value(arg))
            commands << [:heap, :save]
            opt[:skip_children] = true
            lvars << var_addr
          in [:DEFN, name, [:SCOPE, lvar_table, [:ARGS, args_count ,*_], body]]
            m = [
              [:flow, :def, str_to_int(name, type: :method)],
            ]
            lvar_table[0...args_count].reverse.each do |args_name|
              m << [:stack, :push, str_to_int(args_name, type: :variable)]
              m << [:stack, :swap]
              m << [:heap, :save]
            end
            m.concat(ast_to_commands(body, main: false))
            m << [:flow, :end]

            methods << m
            opt[:skip_children] = true
          in [:SCOPE, *_] | [:BLOCK, *_]
            # skip
          in [:VCALL, name]
            with_storing_lvars(lvars, commands) do
              commands << [:flow, :call, str_to_int(name, type: :method)]
            end
            opt[:skip_children] = true
          in [:FCALL, name, [:ARRAY, *args, nil]]
            with_storing_lvars(lvars, commands) do
              args.each do |arg|
                commands.concat(push_value(arg))
              end
              commands << [:flow, :call, str_to_int(name, type: :method)]
            end
            opt[:skip_children] = true
          in [:IF, cond, if_body, else_body]
            commands.concat(compile_if(cond, if_body, else_body))
            opt[:skip_children] = true
          in [:UNLESS, cond, else_body, if_body]
            commands.concat(compile_if(cond, if_body, else_body))
            opt[:skip_children] = true
          end
        end

        commands << [:flow, :exit] if main
        commands.concat(*methods)
        commands
      end

      private def commands_to_ws(commands)
        buf = +""
        commands.each do |command|
          case command
          in [:stack, :push, num]
            buf << SPACE << SPACE << num_to_ws(num)
          in [:stack, :swap]
            buf << SPACE << NL << TAB
          in [:heap, :save]
            buf << TAB << TAB << SPACE
          in [:heap, :load]
            buf << TAB << TAB << TAB
          in [:io, :write_char]
            buf << TAB << NL << SPACE << SPACE
          in [:io, :write_num]
            buf << TAB << NL << SPACE << TAB
          in [:io, :read_char]
            buf << TAB << NL << TAB << SPACE
          in [:io, :read_num]
            buf << TAB << NL << TAB << NL
          in [:flow, :exit]
            buf << NL << NL << NL
          in [:flow, :call, num]
            buf << NL << SPACE << TAB << num_to_ws(num)
          in [:flow, :def, num]
            buf << NL << SPACE << SPACE << num_to_ws(num)
          in [:flow, :end]
            buf << NL << TAB << NL
          in [:flow, :jump_if_zero, label]
            buf << NL << TAB << SPACE << num_to_ws(label)
          in [:flow, :jump, label]
            buf << NL << SPACE << NL << num_to_ws(label)
          in [:flow, :jump_if_neg, label]
            buf << NL << TAB << TAB << num_to_ws(label)
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
        in [:VCALL, :get_as_number]
          tmp_var = str_to_int("__tmp", type: :variable)
          commands << [:stack, :push, tmp_var]
          commands << [:io, :read_num]
          commands << [:stack, :push, tmp_var]
          commands << [:heap, :load]
        in [:VCALL, :get_as_char]
          tmp_var = str_to_int("__tmp", type: :variable)
          commands << [:stack, :push, tmp_var]
          commands << [:io, :read_char]
          commands << [:stack, :push, tmp_var]
          commands << [:heap, :load]
        end

        commands
      end

      private def compile_if(cond, if_body, else_body)
        commands = []
        else_label = str_to_int("else_#{next_label_index}", type: :condition)
        end_label = str_to_int("end_#{next_label_index}", type: :condition)

        body = -> (x, sym) do
          commands.concat(push_value(x))
          commands << [:flow, sym, else_label]
          commands.concat(ast_to_commands(else_body, main: false)) if else_body
          commands << [:flow, :jump, end_label]
          commands << [:flow, :def, else_label]
          commands.concat(ast_to_commands(if_body, main: false)) if if_body
          commands << [:flow, :def, end_label]
        end

        lt_zero = -> (x) do
          commands.concat(push_value(x))
        end

        case cond
        in [:OPCALL, [:LIT, 0], :==, [:ARRAY, x, nil]]
          body.(x, :jump_if_zero)
        in [:OPCALL, x, :==, [:ARRAY, [:LIT, 0], nil]]
          body.(x, :jump_if_zero)
        in [:OPCALL, x, :<, [:ARRAY, [:LIT, 0], nil]]
          body.(x, :jump_if_neg)
        in [:OPCALL, [:LIT, 0], :<, [:ARRAY, x, nil]]
          body.(x, :jump_if_neg)
        end

        commands
      end

      private def check_char!(char)
        raise ParserError, "String size must be 1, but it's #{char} (#{char.size})" if char.size != 1
      end

      private def str_to_int(str, type:)
        prefix =
          case type
          when :variable  then 'v'
          when :method    then 'f'
          when :condition then 'c'
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

      private def next_label_index
        @label_index += 1
      end
    end
  end
end
