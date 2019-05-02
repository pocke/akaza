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

    NONE_ADDR = 0
    TMP_ADDR = 1

    TYPE_BITS = 2

    TYPE_INT   = 0b01
    TYPE_ARRAY = 0b10

    # Call when stack top is the target number.
    UNWRAP_COMMANDS = [
      [:stack, :push, 2 ** TYPE_BITS],
      [:calc, :div],
    ].freeze
    WRAP_NUMBER_COMMANDS = [
      [:stack, :push, 2 ** TYPE_BITS],
      [:calc, :multi],
      [:stack, :push, TYPE_INT],
      [:calc, :add],
    ].freeze
    WRAP_ARRAY_COMMANDS = [
      [:stack, :push, 2 ** TYPE_BITS],
      [:calc, :multi],
      [:stack, :push, TYPE_ARRAY],
      [:calc, :add],
    ].freeze

    class ParseError < StandardError; end

    def self.ruby_to_ws(ruby_code)
      Transpiler.new(ruby_code).transpile
    end

    class Transpiler
      def initialize(ruby_code)
        @ruby_code = ruby_code

        @addr_index = 1
        @addrs = {}

        @label_index = 0
        @labels = {}
      end

      def transpile
        ast = RubyVM::AbstractSyntaxTree.parse(@ruby_code)
        commands = compile_stmt(ast, main: true)
        commands_to_ws(commands)
      end

      private def compile_stmt(ast, main:)
        commands = []
        methods = []
        lvars = []

        ast.traverse do |node, opt|
          case node
          in [:FCALL, :put_as_number, [:ARRAY, arg, nil]]
            commands.concat(compile_expr(arg))
            commands.concat(UNWRAP_COMMANDS)
            commands << [:io, :write_num]
            opt[:skip_children] = true
          in [:FCALL, :put_as_char, [:ARRAY, arg, nil]]
            commands.concat(compile_expr(arg))
            commands.concat(UNWRAP_COMMANDS)
            commands << [:io, :write_char]
            opt[:skip_children] = true
          in [:VCALL, :exit]
            commands << [:flow, :exit]
          in [:LASGN, var, arg]
            var_addr = ident_to_addr(var)
            commands << [:stack, :push, var_addr]
            commands.concat(compile_expr(arg))
            commands << [:heap, :save]
            opt[:skip_children] = true
            lvars << var_addr
          in [:DEFN, name, [:SCOPE, lvar_table, [:ARGS, args_count ,*_], body]]
            m = [
              [:flow, :def, ident_to_label(name)],
            ]
            lvar_table[0...args_count].reverse.each do |args_name|
              m << [:stack, :push, ident_to_addr(args_name)]
              m << [:stack, :swap]
              m << [:heap, :save]
            end
            m.concat(compile_stmt(body, main: false))
            m << [:flow, :end]

            methods << m
            opt[:skip_children] = true
          in [:SCOPE, *_] | [:BLOCK, *_]
            # skip
          in [:VCALL, name]
            with_storing_lvars(lvars, commands) do
              commands << [:flow, :call, ident_to_label(name)]
            end
            opt[:skip_children] = true
          in [:FCALL, name, [:ARRAY, *args, nil]]
            with_storing_lvars(lvars, commands) do
              args.each do |arg|
                commands.concat(compile_expr(arg))
              end
              commands << [:flow, :call, ident_to_label(name)]
            end
            opt[:skip_children] = true
          in [:CALL, recv, :unshift, [:ARRAY, expr, nil]]
            commands.concat(compile_expr(recv))
            commands.concat(UNWRAP_COMMANDS)
            # stack: [unwrapped_addr_of_array]

            commands << [:stack, :dup]
            commands << [:heap, :load]
            # stack: [unwrapped_addr_of_array, addr_of_first_item]

            # Allocate a new item
            new_item_value_addr = next_addr_index
            new_item_addr_addr = next_addr_index
            commands << [:stack, :push, new_item_value_addr]
            commands.concat(compile_expr(expr))
            commands << [:heap, :save]
            commands << [:stack, :push, new_item_addr_addr]
            commands << [:stack, :swap]
            commands << [:heap, :save]
            # stack: [unwrapped_addr_of_array]

            commands << [:stack, :push, new_item_value_addr]
            commands << [:heap, :save]

            opt[:skip_children] = true
          in [:IF, cond, if_body, else_body]
            commands.concat(compile_if(cond, if_body, else_body))
            opt[:skip_children] = true
          in [:UNLESS, cond, else_body, if_body]
            commands.concat(compile_if(cond, if_body, else_body))
            opt[:skip_children] = true
          in [:WHILE, cond, body]
            commands.concat(compile_while(cond, body))
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
          in [:stack, :dup]
            buf << SPACE << NL << SPACE
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
            buf << TAB << NL << TAB << TAB
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
          in [:calc, :add]
            buf << TAB << SPACE << SPACE << SPACE
          in [:calc, :sub]
            buf << TAB << SPACE << SPACE << TAB
          in [:calc, :multi]
            buf << TAB << SPACE << SPACE << NL
          in [:calc, :div]
            buf << TAB << SPACE << TAB << SPACE
          in [:calc, :mod]
            buf << TAB << SPACE << TAB << TAB
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
        end

        block.call

        lvars.size.times do
          commands << [:heap, :save]
        end
      end

      private def compile_expr(ast)
        commands = []

        case ast
        in [:LIT, num]
          commands << [:stack, :push, num_with_type(num)]
        in [:STR, str]
          check_char!(str)
          commands << [:stack, :push, num_with_type(str.ord)]
        in [:LVAR, name]
          commands << [:stack, :push, ident_to_addr(name)]
          commands << [:heap, :load]
        in [:VCALL, :get_as_number]
          commands << [:stack, :push, TMP_ADDR]
          commands << [:io, :read_num]
          commands << [:stack, :push, TMP_ADDR]
          commands << [:heap, :load]
          commands.concat(WRAP_NUMBER_COMMANDS)
        in [:VCALL, :get_as_char]
          commands << [:stack, :push, TMP_ADDR]
          commands << [:io, :read_char]
          commands << [:stack, :push, TMP_ADDR]
          commands << [:heap, :load]
          commands.concat(WRAP_NUMBER_COMMANDS)
        in [:OPCALL, l, sym, [:ARRAY, r, nil]]
          com = {'+': :add, '-': :sub, '*': :multi, '/': :div, '%': :mod}[sym]
          raise ParserError, "Unknown symbol: #{sym}" unless com
          commands.concat(compile_expr(l))
          commands.concat(UNWRAP_COMMANDS)
          commands.concat(compile_expr(r))
          commands.concat(UNWRAP_COMMANDS)
          commands << [:calc, com]
          commands.concat(WRAP_NUMBER_COMMANDS)
        in [:CALL, expr, :shift, nil]
          commands.concat(compile_expr(expr))
          commands.concat(UNWRAP_COMMANDS)
          # stack: [unwrapped_addr_of_array]

          commands << [:stack, :dup]
          commands << [:heap, :load]
          # stack: [unwrapped_addr_of_array, addr_of_first_item]
          commands << [:stack, :swap]
          commands << [:stack, :dup]
          commands << [:heap, :load]
          # stack: [addr_of_first_item, unwrapped_addr_of_array, addr_of_first_item]

          commands << [:stack, :push, 1]
          commands << [:calc, :add]
          commands << [:heap, :load]
          # stack: [addr_of_first_item, unwrapped_addr_of_array, addr_of_second_item]

          commands << [:heap, :save]
          # stack: [addr_of_first_item]

          commands << [:heap, :load]
          # stack: [first_item]
        in [:ARRAY, *items, nil]
          array_addr = next_addr_index
          addrs = ((items.size) * 2).times.map { next_addr_index }
          commands << [:stack, :push, array_addr]
          commands << [:stack, :push, addrs[0] || NONE_ADDR]
          commands << [:heap, :save]

          items.each.with_index do |item, index|
            value_addr = addrs[index * 2]
            commands << [:stack, :push, value_addr]
            commands.concat(compile_expr(item))
            commands << [:heap, :save]

            next_addr = addrs[index * 2 + 1]
            val = addrs[(index + 1) * 2] || NONE_ADDR
            commands << [:stack, :push, next_addr]
            commands << [:stack, :push, val]
            commands << [:heap, :save]
          end

          commands << [:stack, :push, array_with_type(array_addr)]
        in [:ZARRAY]
          addr = next_addr_index
          commands << [:stack, :push, addr]
          commands << [:stack, :push, NONE_ADDR]
          commands << [:heap, :save]
          commands << [:stack, :push, array_with_type(addr)]
        end

        commands
      end

      private def compile_if(cond, if_body, else_body)
        commands = []
        else_label = ident_to_label(nil)
        end_label = ident_to_label(nil)

        body = -> (x, sym) do
          commands.concat(compile_expr(x))
          commands.concat(UNWRAP_COMMANDS)
          commands << [:flow, sym, else_label]
          commands.concat(compile_stmt(else_body, main: false)) if else_body
          commands << [:flow, :jump, end_label]
          commands << [:flow, :def, else_label]
          commands.concat(compile_stmt(if_body, main: false)) if if_body
          commands << [:flow, :def, end_label]
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

      private def compile_while(cond, body)
        commands = []
        cond_label = ident_to_label(nil)
        body_label = ident_to_label(nil)
        end_label = ident_to_label(nil)

        make_body = -> (x, sym) do
          commands << [:flow, :def, cond_label]
          commands.concat(compile_expr(x))
          commands.concat(UNWRAP_COMMANDS)
          commands << [:flow, sym, body_label]
          commands << [:flow, :jump, end_label]
          commands << [:flow, :def, body_label]
          commands.concat(compile_stmt(body, main: false))
          commands << [:flow, :jump, cond_label]
          commands << [:flow, :def, end_label]
        end

        case cond
        in [:OPCALL, [:LIT, 0], :==, [:ARRAY, x, nil]]
          make_body.(x, :jump_if_zero)
        in [:OPCALL, x, :==, [:ARRAY, [:LIT, 0], nil]]
          make_body.(x, :jump_if_zero)
        in [:OPCALL, x, :<, [:ARRAY, [:LIT, 0], nil]]
          make_body.(x, :jump_if_neg)
        in [:OPCALL, [:LIT, 0], :<, [:ARRAY, x, nil]]
          make_body.(x, :jump_if_neg)
        end

        commands
      end

      private def check_char!(char)
        raise ParserError, "String size must be 1, but it's #{char} (#{char.size})" if char.size != 1
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

      private def ident_to_label(ident)
        if ident
          @labels[ident] ||= next_label_index
        else
          next_label_index
        end
      end

      private def next_addr_index
        @addr_index += 1
      end

      private def ident_to_addr(ident)
        @addrs[ident] ||= next_addr_index
      end

      private def num_with_type(num)
        (num << TYPE_BITS) + TYPE_INT
      end

      private def array_with_type(array_addr)
        (array_addr << TYPE_BITS) + TYPE_ARRAY
      end
    end
  end
end
