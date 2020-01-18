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
    MethodDefinition = Struct.new(:name, :lvar_table, :args_count, :body, :klass, keyword_init: true)

    using AstExt

    SPACE = ' '
    TAB = "\t"
    NL = "\n"

    NONE_ADDR = 0
    TMP_ADDR = 1
    HEAP_COUNT_ADDR = 2

    TYPES = %w[Integer Hash Array]
    TYPE_BITS = 2

    TYPE_SPECIAL = 0b00
    TYPE_INT     = 0b01
    TYPE_ARRAY   = 0b10
    TYPE_HASH    = 0b11

    HASH_SIZE = 11

    ARRAY_FIRST_CAPACITY = 10

    FALSE = 0 << TYPE_BITS + TYPE_SPECIAL
    # NONE is for internal. It does not available for user.
    NONE = 1 << TYPE_BITS + TYPE_SPECIAL
    TRUE = 2 << TYPE_BITS + TYPE_SPECIAL
    # NIL is nil
    NIL = 4 << TYPE_BITS + TYPE_SPECIAL

    # Classes
    CLASS_SPECIAL = (8 + TYPE_SPECIAL) << TYPE_BITS + TYPE_SPECIAL
    CLASS_INT = (8 + TYPE_INT) << TYPE_BITS + TYPE_SPECIAL
    CLASS_ARRAY = (8 + TYPE_ARRAY) << TYPE_BITS + TYPE_SPECIAL
    CLASS_HASH = (8 + TYPE_HASH) << TYPE_BITS + TYPE_SPECIAL

    # Call when stack top is the target number.
    UNWRAP_COMMANDS = [
      [:stack_push, 2 ** TYPE_BITS],
      [:calc_div],
    ].freeze
    WRAP_NUMBER_COMMANDS = [
      [:stack_push, 2 ** TYPE_BITS],
      [:calc_multi],
      [:stack_push, TYPE_INT],
      [:calc_add],
    ].freeze
    WRAP_ARRAY_COMMANDS = [
      [:stack_push, 2 ** TYPE_BITS],
      [:calc_multi],
      [:stack_push, TYPE_ARRAY],
      [:calc_add],
    ].freeze
    WRAP_HASH_COMMANDS = [
      [:stack_push, 2 ** TYPE_BITS],
      [:calc_multi],
      [:stack_push, TYPE_HASH],
      [:calc_add],
    ].freeze
    SAVE_TMP_COMMANDS = [
      [:stack_push, TMP_ADDR],
      [:stack_swap],
      [:heap_save],
    ].freeze
    LOAD_TMP_COMMANDS = [
      [:stack_push, TMP_ADDR],
      [:heap_load],
    ].freeze
    # Allocate heap and push allocated address to the stack
    ALLOCATE_HEAP_COMMANDS = [
      [:stack_push, HEAP_COUNT_ADDR],
      [:heap_load],
      [:stack_push, 1],
      [:calc_add],
      [:stack_dup],
      [:stack_push, HEAP_COUNT_ADDR],
      [:stack_swap],
      [:heap_save],
    ].freeze
    # Allocate N size heap and push nothing
    # stack: [N]
    # return stack: []
    ALLOCATE_N_HEAP_COMMANDS = [
      [:stack_push, HEAP_COUNT_ADDR],
      [:heap_load],
      [:calc_add],
      [:stack_push, HEAP_COUNT_ADDR],
      [:stack_swap],
      [:heap_save],
    ].freeze
    # Return an address that will be allocated by ALLOCATE_HEAP_COMMANDS
    NEXT_HEAP_ADDRESS = [
      [:stack_push, HEAP_COUNT_ADDR],
      [:heap_load],
      [:stack_push, 1],
      [:calc_add],
    ].freeze
    ALLOCATE_NEW_HASH_ITEM_COMMANDS = [
      *ALLOCATE_HEAP_COMMANDS,
      [:stack_dup],
      [:stack_push, NONE],
      [:heap_save],
      *ALLOCATE_HEAP_COMMANDS,
      [:stack_pop],
      *ALLOCATE_HEAP_COMMANDS,
      [:stack_pop],
    ].freeze

    prelude_path = File.expand_path('./ruby2ws/prelude.rb', __dir__)
    PRELUDE_AST = RubyVM::AbstractSyntaxTree.parse(File.read(prelude_path))

    class ParseError < StandardError; end

    def self.ruby_to_ws(ruby_code, path: '(eval)')
      Transpiler.new(ruby_code, path: path).transpile
    end

    class Transpiler
      # @param ruby_code [String]
      # @param path [String] For debug information
      def initialize(ruby_code, path:)
        @ruby_code = ruby_code
        @path = path

        @variable_addr_index = 2
        @variable_addrs = {}

        @label_index = 0
        @labels = {}

        # Method list to compile
        # Array<Array<Command>>
        @methods = []

        # For lazy compiling method.
        # MethodDefinition is inserted to it on :DEFN node.
        # The definition is compiled on call node, such as :CALL.
        # Hash{Symbol => Array<MethodDefinition>}
        @method_definitions = {}

        @method_table = {
          Array: [:size, :push, :pop, :[], :[]=],
          Integer: [:<=>],
          Hash: [:[], :[]=],
        }

        @lvars_stack = []

        @current_class = nil
      end

      def transpile
        commands = []
        # define built-in functions
        define_array_size
        define_array_pop
        define_array_push
        define_array_ref
        define_array_attr_asgn
        define_hash_ref
        define_hash_attr_asgn
        define_op_spaceship

        # Prelude
        commands.concat compile_expr(PRELUDE_AST)

        ast = RubyVM::AbstractSyntaxTree.parse(@ruby_code)
        body = compile_expr(ast)

        # Save self for top level
        commands << [:stack_push, variable_name_to_addr(:self)]
        commands << [:stack_push, NONE]
        commands << [:heap_save]

        # Reserve heaps for local variables
        commands << [:stack_push, HEAP_COUNT_ADDR]
        commands << [:stack_push, @variable_addr_index + 1]
        commands << [:heap_save]

        commands.concat body
        commands << [:flow_exit]
        commands.concat(*@methods)
        commands_to_ws(commands)
      end

      private def compile_expr(node)
        commands = []

        case node
        in [:FCALL, :put_as_number, [:ARRAY, arg, nil]]
          commands.concat(compile_expr(arg))
          commands.concat(UNWRAP_COMMANDS)
          commands << [:io_write_num]
          commands << [:stack_push, NIL]
        in [:FCALL, :put_as_char, [:ARRAY, arg, nil]]
          commands.concat(compile_expr(arg))
          commands.concat(UNWRAP_COMMANDS)
          commands << [:io_write_char]
          commands << [:stack_push, NIL]
        in [:FCALL, :raise, [:ARRAY, [:STR, str], nil]]
          commands.concat compile_raise(str, node)
        in [:VCALL, :get_as_number]
          commands << [:stack_push, TMP_ADDR]
          commands << [:io_read_num]
          commands << [:stack_push, TMP_ADDR]
          commands << [:heap_load]
          commands.concat(WRAP_NUMBER_COMMANDS)
        in [:VCALL, :get_as_char]
          commands << [:stack_push, TMP_ADDR]
          commands << [:io_read_char]
          commands << [:stack_push, TMP_ADDR]
          commands << [:heap_load]
          commands.concat(WRAP_NUMBER_COMMANDS)
        in [:OPCALL, l, :==, [:ARRAY, r, nil]]
          commands.concat compile_expr(l)
          commands.concat compile_expr(r)
          commands << [:flow_call, op_eqeq_label]
        in [:OPCALL, l, :!=, [:ARRAY, r, nil]]
          commands.concat compile_expr(l)
          commands.concat compile_expr(r)
          commands << [:flow_call, op_eqeq_label]
          commands << [:flow_call, op_not_label]
        in [:OPCALL, recv, :!, nil]
          commands.concat compile_expr(recv)
          commands << [:flow_call, op_not_label]
        in [:OPCALL, l, :+ | :- | :* | :/ | :% => sym, [:ARRAY, r, nil]]
          com = {'+': :calc_add, '-': :calc_sub, '*': :calc_multi, '/': :calc_div, '%': :calc_mod}[sym]
          commands.concat(compile_expr(l))
          commands.concat(UNWRAP_COMMANDS)
          commands.concat(compile_expr(r))
          commands.concat(UNWRAP_COMMANDS)
          commands << [com]
          commands.concat(WRAP_NUMBER_COMMANDS)
        in [:OPCALL, recv, op, [:ARRAY, *args, nil]]
          commands.concat compile_expr(recv)
          commands.concat compile_call_with_recv(op, args, error_target_node: recv, explicit_self: true)
        in [:VCALL, :exit]
          commands << [:flow_exit]
        in [:LASGN, var, arg]
          commands.concat(compile_expr(arg))
          commands << [:stack_dup]
          var_addr = variable_name_to_addr(var)
          commands << [:stack_push, var_addr]
          commands << [:stack_swap]
          commands << [:heap_save]
        in [:CDECL, var, arg]
          commands.concat(compile_expr(arg))
          commands << [:stack_dup]
          var_addr = variable_name_to_addr(var)
          commands << [:stack_push, var_addr]
          commands << [:stack_swap]
          commands << [:heap_save]
        in [:ATTRASGN, recv, :[]=, [:ARRAY, index, value, nil]]
          commands.concat compile_expr(recv)
          commands.concat compile_call_with_recv(:[]=, [index, value], error_target_node: node, explicit_self: true)
        in [:DEFN, name, [:SCOPE, lvar_table, [:ARGS, args_count ,*_], body]]
          (@method_definitions[name] ||= []) << MethodDefinition.new(
            name: name,
            lvar_table: lvar_table,
            args_count: args_count,
            body: body,
            klass: @current_class
          )
          commands << [:stack_push, NIL] # def foo... returns nil
        in [:CLASS, [:COLON2, nil, class_name], nil, scope]
          raise ParseError, "Class cannot be nested, but #{@current_class}::#{class_name} is nested." if @current_class
          @current_class = class_name
          commands.concat compile_expr(scope)
          @current_class = nil
        in [:SCOPE, lvar_table, _, body]
          commands.concat update_lvar_commands(lvar_table)
          commands.concat(compile_expr(body))
          @lvars_stack.pop
        in [:BEGIN, nil]
          # skip
          # It is available in class definition.
          commands << [:stack_push, NIL]
        in [:SELF]
          commands.concat load_from_self_commands
        in [:BLOCK, *children]
          children.each.with_index do |child, index|
            commands.concat(compile_expr(child))
            commands << [:stack_pop] unless index == children.size - 1
          end
        in [:VCALL, name]
          commands << [:stack_push, variable_name_to_addr(:self)]
          commands << [:heap_load]
          commands.concat compile_call_with_recv(name, [], error_target_node: node, explicit_self: false)
        in [:FCALL, name, [:ARRAY, *args, nil]]
          commands << [:stack_push, variable_name_to_addr(:self)]
          commands << [:heap_load]
          commands.concat compile_call_with_recv(name, args, error_target_node: node, explicit_self: false)
        in [:CALL, recv, :is_a?, [:ARRAY, klass, nil]]
          true_label = ident_to_label(nil)
          end_label = ident_to_label(nil)
          commands.concat compile_expr(recv)
          commands.concat compile_expr(klass)
          # klass to type
          commands.concat UNWRAP_COMMANDS
          commands << [:stack_push, 8]
          commands << [:calc_sub]

          commands << [:stack_swap]
          commands << [:flow_call, is_a_label]
          commands << [:flow_jump_if_zero, true_label]

          commands << [:stack_push, FALSE]
          commands << [:flow_jump, end_label]

          commands << [:flow_def, true_label]
          commands << [:stack_push, TRUE]

          commands << [:flow_def, end_label]
        in [:CALL, recv, name, [:ARRAY, *args, nil]]
          commands.concat compile_expr(recv)
          commands.concat compile_call_with_recv(name, args, error_target_node: recv, explicit_self: true)
        in [:CALL, recv, name, nil]
          args = []
          commands.concat compile_expr(recv)
          commands.concat compile_call_with_recv(name, args, error_target_node: recv, explicit_self: true)
        in [:IF, cond, if_body, else_body]
          commands.concat(compile_if(cond, if_body, else_body))
        in [:UNLESS, cond, else_body, if_body]
          commands.concat(compile_if(cond, if_body, else_body))
        in [:CASE, cond, first_when]
          commands.concat compile_case(cond, first_when)
        in [:WHILE, cond, body, true]
          commands.concat(compile_while(cond, body))
        in [:LIT, num]
          commands << [:stack_push, with_type(num, TYPE_INT)]
        in [:STR, str]
          check_char!(str)
          commands << [:stack_push, with_type(str.ord, TYPE_INT)]
        in [:TRUE]
          commands << [:stack_push, TRUE]
        in [:FALSE]
          commands << [:stack_push, FALSE]
        in [:NIL]
          commands << [:stack_push, NIL]
        in [:LVAR, name]
          commands << [:stack_push, variable_name_to_addr(name)]
          commands << [:heap_load]
        in [:CONST, :Integer | :Array | :Hash | :Special => klass]
          k = {
            Integer: CLASS_INT,
            Array: CLASS_ARRAY,
            Hash: CLASS_HASH,
            Special: CLASS_SPECIAL,
          }[klass]
          commands << [:stack_push, k]
        in [:CONST, name]
          commands << [:stack_push, variable_name_to_addr(name)]
          commands << [:heap_load]
        in [:ARRAY, *items, nil]
          commands.concat allocate_array_commands(items.size)
          # stack: [array]

          commands << [:stack_dup]
          commands.concat UNWRAP_COMMANDS
          commands << [:stack_push, 3]
          commands << [:calc_add]
          # stack: [array, first_item_addr]

          items.each do |item|
            commands << [:stack_dup]
            # stack: [array, item_addr, item_addr]
            commands.concat compile_expr(item)
            commands << [:heap_save]
            commands << [:stack_push, 1]
            commands << [:calc_add]
            # stack: [array, next_item_addr]
          end
          commands << [:stack_pop]

        in [:ZARRAY]
          # Allocate array ref
          commands.concat allocate_array_commands(0)
        in [:HASH, nil]
          commands.concat initialize_hash
        in [:HASH, [:ARRAY, *pairs, nil]]
          commands.concat initialize_hash
          commands << [:stack_dup]
          commands.concat UNWRAP_COMMANDS
          commands.concat SAVE_TMP_COMMANDS
          # stack: [hash_object (unwrapped)]
          # tmp: hash_object (unwrapped)

          pairs.each_slice(2) do |key, value|
            no_collision_label = ident_to_label(nil)
            check_collision_label = ident_to_label(nil)
            when_not_allocated = ident_to_label(nil)

            commands.concat(compile_expr(key))
            # calc hash
            commands << [:stack_dup]
            commands.concat(UNWRAP_COMMANDS)
            commands << [:stack_push, HASH_SIZE]
            commands << [:calc_mod]
            commands << [:stack_push, 3]
            commands << [:calc_multi]
            # stack: [key, hash]

            commands.concat LOAD_TMP_COMMANDS
            commands << [:stack_push, 1]
            commands << [:calc_add] # hash_addr + 1 is the first item's address.
            commands << [:calc_add]
            # stack: [key, key_addr]

            # Check collision
            commands << [:flow_def, check_collision_label]
            commands << [:stack_dup]
            commands << [:heap_load]
            commands << [:stack_push, NONE]
            commands << [:calc_sub]
            # stack: [key, key_addr, is_none]

            commands << [:flow_jump_if_zero, no_collision_label]

            # when collision
            commands << [:stack_push, 2]
            commands << [:calc_add]
            # stack: [key, next_addr]
            commands << [:stack_dup]
            commands << [:heap_load]
            commands << [:stack_push, NONE_ADDR]
            commands << [:calc_sub]
            commands << [:flow_jump_if_zero, when_not_allocated]
            # stack: [key, next_addr]

            # when next field is already allocated
            commands << [:heap_load]
            # stack: [key, next_key_addr]
            commands << [:flow_jump, check_collision_label]

            # when next field is not allocated
            commands << [:flow_def, when_not_allocated]
            # stack: [key, next_addr]
            commands << [:stack_dup]
            commands.concat ALLOCATE_NEW_HASH_ITEM_COMMANDS
            commands << [:heap_save]
            commands << [:heap_load]

            commands << [:flow_jump, check_collision_label]

            commands << [:flow_def, no_collision_label]
            # End check collision

            # stack: [key, key_addr]
            # Save value
            commands << [:stack_dup]
            commands << [:stack_push, 1]
            commands << [:calc_add]
            commands.concat(compile_expr(value))
            # stack: [key, key_addr, value_addr, value]
            commands << [:heap_save]
            # stack: [key, key_addr]

            # Save next addr
            commands << [:stack_dup]
            commands << [:stack_push, 2]
            commands << [:calc_add]
            # stack: [key, key_addr, next_addr]
            commands << [:stack_push, NONE_ADDR]
            commands << [:heap_save]
            # stack: [key, key_addr]

            # Save key
            commands << [:stack_swap]
            commands << [:heap_save]
          end
        end

        commands
      end

      private def commands_to_ws(commands)
        buf = +""
        commands.each do |command|
          case command
          in [:stack_push, num]
            buf << SPACE << SPACE << num_to_ws(num)
          in [:stack_pop]
            buf << SPACE << NL << NL
          in [:stack_swap]
            buf << SPACE << NL << TAB
          in [:stack_dup]
            buf << SPACE << NL << SPACE
          in [:heap_save]
            buf << TAB << TAB << SPACE
          in [:heap_load]
            buf << TAB << TAB << TAB
          in [:io_write_char]
            buf << TAB << NL << SPACE << SPACE
          in [:io_write_num]
            buf << TAB << NL << SPACE << TAB
          in [:io_read_char]
            buf << TAB << NL << TAB << SPACE
          in [:io_read_num]
            buf << TAB << NL << TAB << TAB
          in [:flow_exit]
            buf << NL << NL << NL
          in [:flow_call, num]
            buf << NL << SPACE << TAB << num_to_ws(num)
          in [:flow_def, num]
            buf << NL << SPACE << SPACE << num_to_ws(num)
          in [:flow_end]
            buf << NL << TAB << NL
          in [:flow_jump_if_zero, label]
            buf << NL << TAB << SPACE << num_to_ws(label)
          in [:flow_jump, label]
            buf << NL << SPACE << NL << num_to_ws(label)
          in [:flow_jump_if_neg, label]
            buf << NL << TAB << TAB << num_to_ws(label)
          in [:calc_add]
            buf << TAB << SPACE << SPACE << SPACE
          in [:calc_sub]
            buf << TAB << SPACE << SPACE << TAB
          in [:calc_multi]
            buf << TAB << SPACE << SPACE << NL
          in [:calc_div]
            buf << TAB << SPACE << TAB << SPACE
          in [:calc_mod]
            buf << TAB << SPACE << TAB << TAB
          end
        end
        buf
      end

      private def with_storing_lvars(commands, &block)
        lvars.each do |var_addr|
          # stack.push(addr); stack.push(val)
          commands << [:stack_push, var_addr]
          commands << [:stack_push, var_addr]
          commands << [:heap_load]
        end

        block.call

        lvars.size.times do
          commands << [:heap_save]
        end
      end

      # stack: [recv]
      private def compile_call(name, args)
        commands = []
        commands.concat SAVE_TMP_COMMANDS
        with_storing_lvars(commands) do
          # Update self
          commands.concat LOAD_TMP_COMMANDS
          commands.concat save_to_self_commands


          # push args
          args.each do |arg|
            commands.concat(compile_expr(arg))
          end


          commands << [:flow_call, ident_to_label(name)]
          commands << [:stack_push, TMP_ADDR]
          commands << [:stack_swap]
          commands << [:heap_save]
        end
        # restore return value
        commands << [:stack_push, TMP_ADDR]
        commands << [:heap_load]
        commands
      end

      # Compile CALL
      # stack: [recv]
      private def compile_call_with_recv(name, args, error_target_node:, explicit_self:)
        lazy_compile_method(name)

        commands = []

        is_int_label = ident_to_label(nil)
        is_array_label = ident_to_label(nil)
        is_hash_label = ident_to_label(nil)
        is_none_label = ident_to_label(nil)
        end_label = ident_to_label(nil)

        commands << [:stack_dup]
        commands.concat SAVE_TMP_COMMANDS

        # is_a?(Integer)
        commands << [:stack_push, TYPE_INT]
        commands << [:stack_swap]
        commands << [:flow_call, is_a_label]
        commands << [:flow_jump_if_zero, is_int_label]

        # is_a?(Array)
        commands << [:stack_push, TYPE_ARRAY]
        commands.concat LOAD_TMP_COMMANDS
        commands << [:flow_call, is_a_label]
        commands << [:flow_jump_if_zero, is_array_label]

        # is_a?(Hash)
        commands << [:stack_push, TYPE_HASH]
        commands.concat LOAD_TMP_COMMANDS
        commands << [:flow_call, is_a_label]
        commands << [:flow_jump_if_zero, is_hash_label]

        # == NONE
        commands.concat LOAD_TMP_COMMANDS
        commands << [:stack_push, NONE]
        commands << [:calc_sub]
        commands << [:flow_jump_if_zero, is_none_label]

        # Other
        commands.concat compile_raise("Unknown type of receiver", error_target_node)

        top_level_p = -> (type) { !@method_table[type].include?(name) && !explicit_self }

        commands << [:flow_def, is_int_label]
        if top_level_p.(:Integer)
          commands << [:stack_push, NONE]
          commands.concat compile_call(name, args)
        else
          commands.concat LOAD_TMP_COMMANDS
          commands.concat compile_call(:"Integer##{name}", args)
        end
        commands << [:flow_jump, end_label]

        commands << [:flow_def, is_array_label]
        if top_level_p.(:Array)
          commands << [:stack_push, NONE]
          commands.concat compile_call(name, args)
        else
          commands.concat LOAD_TMP_COMMANDS
          commands.concat compile_call(:"Array##{name}", args)
        end
        commands << [:flow_jump, end_label]

        commands << [:flow_def, is_hash_label]
        if top_level_p.(:Hash)
          commands << [:stack_push, NONE]
          commands.concat compile_call(name, args)
        else
          commands.concat LOAD_TMP_COMMANDS
          commands.concat compile_call(:"Hash##{name}", args)
        end
        commands << [:flow_jump, end_label]

        # If receiver is NONE, it means method is called at the top level
        commands << [:flow_def, is_none_label]
        commands << [:stack_push, NONE]
        commands.concat compile_call(name, args)

        commands << [:flow_def, end_label]

        commands
      end

      # required stack: [count]
      # the count in the stack will be modified by this method.
      private def times(&block)
        commands = []
        end_label = ident_to_label(nil)
        cond_label = ident_to_label(nil)

        commands << [:flow_def, cond_label]
        commands << [:stack_push, 1]
        commands << [:calc_sub]
        commands << [:stack_dup]
        commands << [:flow_jump_if_neg, end_label]

        commands.concat(block.call)

        commands << [:flow_jump, cond_label]
        commands << [:flow_def, end_label]

        commands
      end

      private def compile_if(cond, if_body, else_body)
        commands = []

        optimized_body = -> (x, sym) do
          else_label = ident_to_label(nil)
          end_label = ident_to_label(nil)

          commands.concat(compile_expr(x))
          commands.concat(UNWRAP_COMMANDS)
          commands << [sym, else_label]
          if else_body
            commands.concat(compile_expr(else_body))
          else
            commands << [:stack_push, NIL]
          end
          commands << [:flow_jump, end_label]
          commands << [:flow_def, else_label]
          if if_body
            commands.concat(compile_expr(if_body))
          else
            commands << [:stack_push, NIL]
          end
          commands << [:flow_def, end_label]
        end

        case cond
        in [:OPCALL, [:LIT, 0], :==, [:ARRAY, x, nil]]
          optimized_body.(x, :flow_jump_if_zero)
        in [:OPCALL, x, :==, [:ARRAY, [:LIT, 0], nil]]
          optimized_body.(x, :flow_jump_if_zero)
        in [:OPCALL, x, :<, [:ARRAY, [:LIT, 0], nil]]
          optimized_body.(x, :flow_jump_if_neg)
        in [:OPCALL, [:LIT, 0], :<, [:ARRAY, x, nil]]
          optimized_body.(x, :flow_jump_if_neg)
        else
          if_label = ident_to_label(nil)
          end_label = ident_to_label(nil)

          commands.concat compile_expr(cond)
          commands << [:flow_call, rtest_label]
          commands << [:flow_jump_if_zero, if_label]

          # when false
          if else_body
            commands.concat compile_expr(else_body)
          else
            commands << [:stack_push, NIL]
          end
          commands << [:flow_jump, end_label]

          # when true
          commands << [:flow_def, if_label]
          if if_body
            commands.concat compile_expr(if_body)
          else
            commands << [:stack_push, NIL]
          end

          commands << [:flow_def, end_label]
        end

        commands
      end

      private def compile_case(cond, first_when)
        commands = []
        end_label = ident_to_label(nil)

        commands.concat compile_expr(cond)

        bodies = []
        body_labels = []
        else_node = nil

        first_when.each_when do |when_node|
          case when_node
          in [:WHEN, [:ARRAY, *objs, nil], body, _]
            bodies << body
            body_labels << ident_to_label(nil)

            objs.each do |obj|
              commands << [:stack_dup]
              commands.concat compile_expr(obj)
              commands << [:calc_sub]
              commands << [:flow_jump_if_zero, body_labels.last]
            end
          else # When case-else body
            else_node = when_node
          end
        end

        commands << [:stack_pop] # pop cond object
        if else_node
          commands.concat compile_expr(else_node)
        else
          commands << [:stack_push, NIL]
        end
        commands << [:flow_jump, end_label]

        bodies.zip(body_labels).each do |body, label|
          commands << [:flow_def, label]
          commands << [:stack_pop] # pop cond object
          commands.concat compile_expr(body)
          commands << [:flow_jump, end_label]
        end

        commands << [:flow_def, end_label]
        commands
      end

      private def compile_while(cond, body)
        commands = []
        cond_label = ident_to_label(nil)
        body_label = ident_to_label(nil)
        end_label = ident_to_label(nil)

        make_body = -> (x, sym) do
          commands << [:flow_def, cond_label]
          commands.concat(compile_expr(x))
          commands.concat(UNWRAP_COMMANDS)
          commands << [sym, body_label]
          commands << [:flow_jump, end_label]
          commands << [:flow_def, body_label]
          commands.concat(compile_expr(body))
          commands << [:stack_pop]
          commands << [:flow_jump, cond_label]
          commands << [:flow_def, end_label]
          commands << [:stack_push, NIL]
        end

        case cond
        in [:TRUE] # Optimized
          commands << [:flow_def, cond_label]
          commands.concat compile_expr(body)
          commands << [:stack_pop]
          commands << [:flow_jump, cond_label]
        in [:OPCALL, [:LIT, 0], :==, [:ARRAY, x, nil]]
          make_body.(x, :flow_jump_if_zero)
        in [:OPCALL, x, :==, [:ARRAY, [:LIT, 0], nil]]
          make_body.(x, :flow_jump_if_zero)
        in [:OPCALL, x, :<, [:ARRAY, [:LIT, 0], nil]]
          make_body.(x, :flow_jump_if_neg)
        in [:OPCALL, [:LIT, 0], :<, [:ARRAY, x, nil]]
          make_body.(x, :flow_jump_if_neg)
        else
          commands << [:flow_def, cond_label]
          commands.concat(compile_expr(cond))
          commands << [:flow_call, rtest_label]
          commands << [:flow_jump_if_zero, body_label]
          commands << [:flow_jump, end_label]
          commands << [:flow_def, body_label]
          commands.concat(compile_expr(body))
          commands << [:stack_pop]
          commands << [:flow_jump, cond_label]
          commands << [:flow_def, end_label]
          commands << [:stack_push, NIL]
        end

        commands
      end

      private def compile_raise(str, node)
        msg = +"#{@path}:"
        msg << "#{node.first_lineno}:#{node.first_column}"
        msg << ": #{str} (Error)\n"
        commands = []

        msg.bytes.each do |byte|
          commands << [:stack_push, byte]
          commands << [:io_write_char]
        end

        commands << [:flow_exit]

        commands
      end

      private def compile_def(name, lvar_table, args_count, body, klass)
        label = klass ? ident_to_label(:"#{klass}##{name}") : ident_to_label(name)
        m = [
          [:flow_def, label],
        ]
        args = lvar_table[0...args_count].reverse
        m.concat update_lvar_commands(lvar_table, args: args)
        args.each do |args_name|
          addr = variable_name_to_addr(args_name)
          m << [:stack_push, addr]
          m << [:stack_swap]
          m << [:heap_save]
        end

        m.concat(compile_expr(body))
        @lvars_stack.pop
        m << [:flow_end]

        @methods << m

        @method_table[klass] << name if klass
      end

      private def initialize_hash
        commands = []
        # Allocate for Hash
        commands.concat ALLOCATE_HEAP_COMMANDS

        HASH_SIZE.times do
          commands.concat ALLOCATE_NEW_HASH_ITEM_COMMANDS
          commands << [:stack_pop]
        end

        # stack: [hash_addr]
        commands << [:stack_dup]
        commands << [:stack_dup]
        commands << [:stack_push, 1]
        commands << [:calc_add]
        commands << [:heap_save]
        # stack: [hash_addr]

        commands.concat(WRAP_HASH_COMMANDS)

        commands
      end

      # stack: [self]
      # return stack: []
      private def save_to_self_commands
        commands = []
        self_addr = variable_name_to_addr(:self)
        commands << [:stack_push, self_addr]
        commands << [:stack_swap]
        commands << [:heap_save]
        commands
      end

      # stack: []
      # return stack: [self]
      private def load_from_self_commands
        commands = []
        self_addr = variable_name_to_addr(:self)
        commands << [:stack_push, self_addr]
        commands << [:heap_load]
        commands
      end

      # stack: [addr_of_first_addr]
      # return stack: []
      private def realloc_array_label
        @realloc_array_label ||= (
          label = ident_to_label(nil)
          commands = []
          commands << [:flow_def, label]

          # stack: [addr_of_first_addr]
          # Get cap addr
          commands << [:stack_dup]
          commands << [:stack_push, 2]
          commands << [:calc_add]
          commands << [:stack_dup]
          commands << [:heap_load]
          # stack: [addr_of_first_addr, cap_addr, cap]

          commands << [:stack_push, 2]
          commands << [:calc_multi]
          # stack: [addr_of_first_addr, cap_addr, new_cap]
          # Update cap
          commands << [:stack_dup]
          commands.concat SAVE_TMP_COMMANDS
          commands << [:heap_save]
          commands.concat LOAD_TMP_COMMANDS
          # stack: [addr_of_first_addr, new_cap]
          commands.concat NEXT_HEAP_ADDRESS
          commands.concat SAVE_TMP_COMMANDS # new_item_addr
          commands.concat ALLOCATE_N_HEAP_COMMANDS
          # stack: [addr_of_first_addr]
          commands << [:stack_dup]
          commands << [:heap_load]
          # stack: [addr_of_first_addr, old_first_addr]
          # Update first addr
          commands << [:stack_swap]
          commands << [:stack_dup]
          commands.concat LOAD_TMP_COMMANDS
          # stack: [old_first_addr, addr_of_first_addr, addr_of_first_addr, new_first_addr]
          commands << [:heap_save]
          commands << [:stack_swap]
          # stack: [addr_of_first_addr, old_first_addr]
          # Load size
          commands << [:stack_swap]
          commands << [:stack_push, 1]
          commands << [:calc_add]
          commands << [:heap_load]
          # stack: [old_first_addr, size]
          # Move old items to new addresses
          commands.concat(times do
            c = []
            c << [:stack_swap]
            # stack: idx, old_target_addr]
            c << [:stack_dup]
            c.concat LOAD_TMP_COMMANDS
            # stack: [idx, old_target_addr, old_target_addr, new_target_addr]

            # Update tmp to new_next_addr
            c << [:stack_dup]
            c << [:stack_push, 1]
            c << [:calc_add]
            c.concat SAVE_TMP_COMMANDS

            # stack: [idx, old_target_addr, old_target_addr, new_target_addr]
            c << [:stack_swap]
            c << [:heap_load]
            # stack: [idx, old_target_addr, new_target_addr, old_target]
            c << [:heap_save]
            # stack: [idx, old_target_addr]
            c << [:stack_push, 1]
            c << [:calc_add]
            # stack: [old_next_addr, idx]
            c << [:stack_swap]
            c
          end)
          commands << [:stack_pop] # idx
          commands << [:stack_pop] # old_next_addr


          commands << [:flow_end]
          @methods << commands
          label
        )
      end

      # stack: [left, right]
      # return stack: [TRUE/FALSE]
      private def op_eqeq_label
        @op_eqeq_label ||= (
          label = ident_to_label(nil)
          label_if_zero = ident_to_label(nil)
          label_end = ident_to_label(nil)

          commands = []
          commands << [:flow_def, label]

          commands << [:calc_sub]
          commands << [:flow_jump_if_zero, label_if_zero]
          commands << [:stack_push, FALSE]
          commands << [:flow_jump, label_end]

          commands << [:flow_def, label_if_zero]
          commands << [:stack_push, TRUE]

          commands << [:flow_def, label_end]
          commands << [:flow_end]
          @methods << commands
          label
        )
      end

      # stack: [obj]
      # return stack: [TRUE/FALSE]
      private def op_not_label
        @op_not_label ||= (
          label = ident_to_label(nil)
          true_label = ident_to_label(nil)
          end_label = ident_to_label(nil)

          commands = []
          commands << [:flow_def, label]

          commands << [:flow_call, rtest_label]
          commands << [:flow_jump_if_zero, true_label]

          # when obj is falsy
          commands << [:stack_push, TRUE]
          commands << [:flow_jump, end_label]

          # when obj is truthy
          commands << [:flow_def, true_label]
          commands << [:stack_push, FALSE]

          commands << [:flow_def, end_label]
          commands << [:flow_end]
          @methods << commands
          label
        )
      end

      # stack: [target]
      # return stack: [0/1] if true then 0, if false then 1.
      private def rtest_label
        @rtest_label ||= (
          truthy = 0
          falsy = 1

          label = ident_to_label(nil)
          when_nil_label = ident_to_label(nil)
          when_false_label = ident_to_label(nil)
          end_label = ident_to_label(nil)

          commands = []
          commands << [:flow_def, label]

          commands << [:stack_dup]
          commands << [:stack_push, NIL]
          commands << [:calc_sub]
          commands << [:flow_jump_if_zero, when_nil_label]

          commands << [:stack_push, FALSE]
          commands << [:calc_sub]
          commands << [:flow_jump_if_zero, when_false_label]

          # when truthy
          commands << [:stack_push, truthy]
          commands << [:flow_jump, end_label]

          # when nil
          commands << [:flow_def, when_nil_label]
          commands << [:stack_pop]
          # when false
          commands << [:flow_def, when_false_label]
          commands << [:stack_push, falsy]

          commands << [:flow_def, end_label]
          commands << [:flow_end]
          @methods << commands
          label
        )
      end

      # stack: [type, val]
      # return stack: [int]
      #   if val is a type then 0
      #   if not then other int
      private def is_a_label
        @is_a_label ||= (
          label = ident_to_label(nil)

          commands = []
          commands << [:flow_def, label]

          commands << [:stack_push, 2 ** TYPE_BITS]
          commands << [:calc_mod]
          commands << [:calc_sub]

          commands << [:flow_end]
          @methods << commands
          label
        )
      end

      # stack: [key, hash]
      # return stack: [addr_of_prev_key, addr_of_target_key]
      private def hash_key_to_addr_label
        @hash_key_to_addr_label ||= (
          label = ident_to_label(nil)
          key_not_collision_label = ident_to_label(nil)
          check_key_equivalent_label = ident_to_label(nil)

          commands = []
          commands << [:flow_def, label]

          commands.concat(UNWRAP_COMMANDS)
          commands << [:heap_load]
          commands << [:stack_swap]
          # stack: [addr_of_first_key, key (wrapped)]
          commands << [:stack_dup]
          commands.concat(SAVE_TMP_COMMANDS)

          # calc hash
          # stack: [addr_of_first_key, key (wrapped)]
          commands.concat(UNWRAP_COMMANDS)
          commands << [:stack_push, HASH_SIZE]
          commands << [:calc_mod]
          commands << [:stack_push, 3]
          commands << [:calc_multi]
          # stack: [addr_of_first_key, hash]

          commands << [:calc_add]
          commands << [:stack_push, NONE_ADDR]
          commands << [:stack_swap]
          # stack: [addr_of_prev_key, addr_of_target_key]

          # Check key equivalent
          commands << [:flow_def, check_key_equivalent_label]
          commands << [:stack_dup]
          commands << [:heap_load]
          commands.concat(LOAD_TMP_COMMANDS)
          # stack: [addr_of_prev_key, addr_of_target_key, target_key, key]
          commands << [:calc_sub]
          commands << [:flow_jump_if_zero, key_not_collision_label]
          # stack: [addr_of_prev_key, addr_of_target_key]
          # Check NONE
          commands << [:stack_dup]
          commands << [:heap_load]
          commands << [:stack_push, NONE]
          commands << [:calc_sub]
          commands << [:flow_jump_if_zero, key_not_collision_label]

          # stack: [addr_of_prev_key, addr_of_target_key]

          # when collistion
          # pop prev key
          commands << [:stack_swap]
          commands << [:stack_pop]
          commands << [:stack_dup]
          # stack: [addr_of_target_key, addr_of_target_key]
          commands << [:stack_push, 2]
          commands << [:calc_add]
          # stack: [addr_of_prev_key, addr_of_next_key_addr]
          commands << [:heap_load]
          # stack: [addr_of_prev_key, next_key_addr]
          commands << [:stack_dup]
          commands << [:stack_push, NONE_ADDR]
          commands << [:calc_sub]
          commands << [:flow_jump_if_zero, key_not_collision_label]
          commands << [:flow_jump, check_key_equivalent_label]

          commands << [:flow_def, key_not_collision_label]

          commands << [:flow_end]
          @methods << commands
          label
        )
      end

      # stack: []
      # return stack: [array]
      private def allocate_array_commands(size)
        commands = []

        commands.concat ALLOCATE_HEAP_COMMANDS
        commands << [:stack_dup]
        commands.concat WRAP_ARRAY_COMMANDS
        commands.concat SAVE_TMP_COMMANDS
        # stack: [array_addr_1]

        # Save first addr
        commands << [:stack_dup]
        commands << [:stack_push, 3]
        commands << [:calc_add]
        commands << [:heap_save]
        # stack: []

        # Allocate size
        commands.concat ALLOCATE_HEAP_COMMANDS
        commands << [:stack_push, size]
        commands << [:heap_save]

        # Allocate cap
        cap = ARRAY_FIRST_CAPACITY < size ? size * 2 : ARRAY_FIRST_CAPACITY
        commands.concat ALLOCATE_HEAP_COMMANDS
        commands << [:stack_push, cap]
        commands << [:heap_save]

        # Allocate cap size heaps
        commands << [:stack_push, cap]
        commands.concat ALLOCATE_N_HEAP_COMMANDS

        commands.concat LOAD_TMP_COMMANDS
        # stack: [array]
      end

      # Array#size
      # stack: []
      # return stack: [int]
      private def define_array_size
        label = ident_to_label(:'Array#size')
        commands = []
        commands << [:flow_def, label]

        commands.concat load_from_self_commands
        commands.concat UNWRAP_COMMANDS
        commands << [:stack_push, 1]
        commands << [:calc_add]
        commands << [:heap_load]
        commands.concat WRAP_NUMBER_COMMANDS

        commands << [:flow_end]
        # stack: [size]
        @methods << commands
      end

      # Array#pop
      # stack: []
      # return stack: [obj]
      private def define_array_pop
        label = ident_to_label(:'Array#pop')
        when_empty_label = ident_to_label(nil)
        commands = []
        commands << [:flow_def, label]

        commands.concat load_from_self_commands
        commands.concat UNWRAP_COMMANDS
        commands << [:stack_push, 1]
        commands << [:calc_add]
        commands << [:heap_load]
        # stack: [size]
        # check empty
        commands << [:stack_dup]
        commands << [:flow_jump_if_zero, when_empty_label]

        # when not empty
        # Decrease size
        commands << [:stack_dup]
        commands.concat load_from_self_commands
        commands.concat UNWRAP_COMMANDS
        commands << [:stack_push, 1]
        commands << [:calc_add]
        # stack: [size, size, size_addr]
        commands << [:stack_swap]
        commands << [:stack_push, 1]
        commands << [:calc_sub]
        commands << [:heap_save]
        # Load item
        commands.concat load_from_self_commands
        commands.concat UNWRAP_COMMANDS
        commands << [:heap_load]
        # stack: [size, first_addr]
        commands << [:stack_push, -1]
        commands << [:calc_add]
        commands << [:calc_add]
        # stack: [addr_of_target_item]
        commands << [:heap_load]

        commands << [:flow_end]
        # stack: [target_item]

        commands << [:flow_def, when_empty_label]
        commands << [:stack_pop]
        commands << [:stack_push, NIL]
        commands << [:flow_end]
        # stack: [nil]
        @methods << commands
      end

      # Array#push
      # stack: [item]
      # return stack: [self]
      private def define_array_push
        label = ident_to_label(:'Array#push')
        when_realloc_label = ident_to_label(nil)
        when_no_realloc_label = ident_to_label(nil)
        commands = []
        commands << [:flow_def, label]

        commands.concat load_from_self_commands
        commands.concat(UNWRAP_COMMANDS)
        # stack: [item, addr_of_first_addr]

        # Check realloc necessary
        commands << [:stack_dup]
        commands << [:stack_push, 1]
        commands << [:calc_add]
        # stack: [item, addr_of_first_addr, addr_of_size]
        commands << [:stack_dup]
        commands << [:stack_push, 1]
        commands << [:calc_add]
        # stack: [item, addr_of_first_addr, addr_of_size, addr_of_cap]
        commands << [:heap_load]
        commands << [:stack_swap]
        commands << [:heap_load]
        # stack: [item, addr_of_first_addr, cap, size]
        commands << [:calc_sub]
        commands << [:flow_jump_if_zero, when_realloc_label]
        commands << [:flow_jump, when_no_realloc_label]

        # Realloc
        commands << [:flow_def, when_realloc_label]
        commands << [:stack_dup]
        commands << [:flow_call, realloc_array_label]

        commands << [:flow_def, when_no_realloc_label]

        # Push
        # stack: [item, addr_of_first_addr]
        commands << [:stack_dup]
        commands << [:stack_push, 1]
        commands << [:calc_add]
        commands << [:heap_load]
        # stack: [item, addr_of_first_addr, size]
        commands << [:stack_swap]
        commands << [:heap_load]
        # stack: [item, size, first_addr]
        commands << [:calc_add]
        # stack: [item, addr_of_target]
        commands << [:stack_swap]
        commands << [:heap_save]

        commands.concat load_from_self_commands
        # Update size
        commands << [:stack_dup]
        commands.concat UNWRAP_COMMANDS
        # stack: [self, addr_of_first_addr]
        commands << [:stack_push, 1]
        commands << [:calc_add]
        commands << [:stack_dup]
        commands << [:heap_load]
        # stack: [self, size_addr, size]
        commands << [:stack_push, 1]
        commands << [:calc_add]
        commands << [:heap_save]

        commands << [:flow_end]
        # stack: [self]
        @methods << commands
      end

      # Array#[]
      # stack: [index]
      # return stack: [item]
      private def define_array_ref
        label = ident_to_label(:'Array#[]')

        commands = []
        commands << [:flow_def, label]

        commands.concat(UNWRAP_COMMANDS)
        commands.concat load_from_self_commands
        # stack: [index, recv]
        commands.concat(UNWRAP_COMMANDS)
        commands << [:heap_load]
        # stack: [addr_of_first_item, index]
        commands << [:calc_add]
        # TODO: range check and return nil
        commands << [:heap_load]

        commands << [:flow_end]
        @methods << commands
      end

      # Array#[]=
      # stack: [index, value]
      # return stack: [value]
      private def define_array_attr_asgn
        label = ident_to_label(:'Array#[]=')

        commands = []
        commands << [:flow_def, label]

        commands << [:stack_swap]
        # stack: [value, index]
        commands.concat UNWRAP_COMMANDS
        commands.concat load_from_self_commands
        commands.concat(UNWRAP_COMMANDS)
        commands << [:heap_load]
        # stack: [value, index, first_addr]
        commands << [:calc_add]
        # TODO: range check and realloc
        commands << [:stack_swap]
        # stack: [target_addr, value]
        commands << [:stack_dup]
        commands.concat SAVE_TMP_COMMANDS
        commands << [:heap_save]
        commands.concat LOAD_TMP_COMMANDS
        # stack: [value]

        commands << [:flow_end]
        @methods << commands
      end

      # Hash#[]
      # stack: [key]
      private def define_hash_ref
        label = ident_to_label(:'Hash#[]')
        when_not_found_label = ident_to_label(nil)

        commands = []
        commands << [:flow_def, label]

        commands.concat load_from_self_commands
        commands << [:flow_call, hash_key_to_addr_label]
        # stack: [addr_of_prev_key, addr_of_target_key]

        # pop addr_of_prev_key
        commands << [:stack_swap]
        commands << [:stack_pop]

        # stack: [addr_of_target_key]
        # check NONE_ADDR (chained)
        commands << [:stack_dup]
        commands << [:stack_push, NONE_ADDR]
        commands << [:calc_sub]
        commands << [:flow_jump_if_zero, when_not_found_label]

        # check NONE (not chained)
        commands << [:stack_dup]
        commands << [:heap_load]
        # stack: [addr_of_target_key, target_key]
        commands << [:stack_push, NONE]
        commands << [:calc_sub]
        commands << [:flow_jump_if_zero, when_not_found_label]

        # when found
        commands << [:stack_push, 1]
        commands << [:calc_add]
        # stack: [addr_of_target_value]
        commands << [:heap_load]

        commands << [:flow_end]

        # when not found
        commands << [:flow_def, when_not_found_label]
        commands << [:stack_pop]
        commands << [:stack_push, NIL]
        commands << [:flow_end]
        @methods << commands
      end

      # Hash#[]
      # stack: [key, value]
      private def define_hash_attr_asgn
        label = ident_to_label(:'Hash#[]=')
        when_not_allocated_label = ident_to_label(nil)
        when_allocated_label = ident_to_label(nil)
        after_allocated_label = ident_to_label(nil)
        fill_none_addr_label = ident_to_label(nil)

        commands = []
        commands << [:flow_def, label]

        # stack: [key, value]
        commands << [:stack_swap]
        commands << [:stack_dup]
        commands.concat load_from_self_commands
        # stack: [value, key, key, recv]

        commands << [:flow_call, hash_key_to_addr_label]
        # stack: [value, key, addr_of_prev_key, addr_of_target_key]

        # check NONE_ADDR
        commands << [:stack_dup]
        commands << [:stack_push, NONE_ADDR]
        commands << [:calc_sub]
        commands << [:flow_jump_if_zero, when_not_allocated_label]
        commands << [:flow_jump, when_allocated_label]

        # When not allocated
        commands << [:flow_def, when_not_allocated_label]
        # stack: [value, key, addr_of_prev_key, addr_of_target_key]
        commands << [:stack_pop]
        commands << [:stack_push, 2]
        commands << [:calc_add]
        commands.concat ALLOCATE_NEW_HASH_ITEM_COMMANDS
        # stack: [value, key, addr_of_prev_key, allocated_addr_of_target_key]
        commands << [:stack_dup]
        commands.concat SAVE_TMP_COMMANDS
        commands << [:heap_save]
        commands.concat LOAD_TMP_COMMANDS
        # stack: [value, key, allocated_addr_of_target_key]

        # Fill NONE_ADDR to next
        commands << [:flow_def, fill_none_addr_label]
        commands << [:stack_dup]
        commands << [:stack_push, 2]
        commands << [:calc_add]
        # stack: [value, key, allocated_addr_of_target_key, addr_of_next_key_addr]
        commands << [:stack_push, NONE_ADDR]
        commands << [:heap_save]
        # stack: [value, key, allocated_addr_of_target_key]
        commands << [:flow_jump, after_allocated_label]

        # When allocated
        commands << [:flow_def, when_allocated_label]
        # stack: [value, key, addr_of_prev_key, addr_of_target_key]
        commands << [:stack_swap]
        commands << [:stack_pop]
        # stack: [value, key, addr_of_target_key]
        commands << [:stack_dup]
        commands << [:heap_load]
        commands << [:stack_push, NONE]
        commands << [:calc_sub]
        commands << [:flow_jump_if_zero, fill_none_addr_label]

        # stack: [value, key, addr_of_target_key]
        commands << [:flow_def, after_allocated_label]
        # Save key
        commands << [:stack_dup]
        commands.concat SAVE_TMP_COMMANDS # addr_of_target_key
        commands << [:stack_swap]
        commands << [:heap_save]
        # Save value
        commands.concat LOAD_TMP_COMMANDS # addr_of_target_key
        # stack: [value, addr_of_target_key]
        commands << [:stack_push, 1]
        commands << [:calc_add]
        # stack: [value, addr_of_target_value]
        commands << [:stack_swap]
        commands << [:stack_dup]
        commands.concat SAVE_TMP_COMMANDS
        commands << [:heap_save]
        commands.concat LOAD_TMP_COMMANDS

        commands << [:flow_end]
        @methods << commands
      end

      # Integer#<=>
      # stack: [right]
      # return stack: [-1/0/1]
      #   if left < rigth  then -1
      #   if left == rigth then 0
      #   if left > rigth then 1
      private def define_op_spaceship
        label = ident_to_label(:'Integer#<=>')
        zero_label = ident_to_label(nil)
        end_label = ident_to_label(nil)
        neg_label = ident_to_label(nil)
        commands = []
        commands << [:flow_def, label]

        commands.concat load_from_self_commands
        commands << [:calc_sub]
        commands << [:stack_dup]
        commands << [:flow_jump_if_zero, zero_label]

        commands << [:flow_jump_if_neg, neg_label]

        # if positive
        commands << [:stack_push, with_type(-1, TYPE_INT)]
        commands << [:flow_jump, end_label]

        # if negative
        commands << [:flow_def, neg_label]
        commands << [:stack_push, with_type(1, TYPE_INT)]
        commands << [:flow_jump, end_label]

        # if equal
        commands << [:flow_def, zero_label]
        commands << [:stack_pop]
        commands << [:stack_push, with_type(0, TYPE_INT)]

        commands << [:flow_def, end_label]
        commands << [:flow_end]
        @methods << commands
      end


      private def check_char!(char)
        raise ParseError, "String size must be 1, but it's #{char} (#{char.size})" if char.size != 1
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

      # @param ident [Symbol | nil]
      private def ident_to_label(ident)
        if ident
          ident = ident.to_sym
          @labels[ident] ||= next_label_index
             # .tap {|index| p [ident, num_to_ws(index).chop]}
        else
          next_label_index
             # .tap { |index| p [caller[2], num_to_ws(index).chop] }
        end
      end

      private def variable_addr_index
        @variable_addr_index += 1
      end

      private def variable_name_to_addr(ident)
        @variable_addrs[ident] ||= variable_addr_index
      end

      private def with_type(val, type)
        (val << TYPE_BITS) + type
      end

      private def lvars
        @lvars_stack.last
      end

      private def update_lvar_commands(table, args: [])
        addr_table = table.map do |var_name|
          [var_name, variable_name_to_addr(var_name)]
        end
        commands = []
        addr_table.each do |var_name, addr|
          next if args.include?(var_name)
          commands << [:stack_push, addr]
          commands << [:stack_push, NIL]
          commands << [:heap_save]
        end
        @lvars_stack << addr_table.map{_2}
        lvars << variable_name_to_addr(:self)
        commands
      end

      private def lazy_compile_method(name)
        @method_definitions.delete(name)&.each do |d|
          compile_def(d.name, d.lvar_table, d.args_count, d.body, d.klass)
        end
      end
    end
  end
end
