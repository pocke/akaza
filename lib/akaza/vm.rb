module Akaza
  class VM
    def initialize(commands, input, output)
      @commands = commands
      @input = input
      @output = output
      @stack = []
      @heap = {}
      @call_stack = []
      @index = 0
      @labels = {}

      prepare_label
    end

    def eval
      while true
        case @commands[@index]
        in [:stack, :push, number]
          @stack.push number
        in [:stack, :dup]
          @stack.push @stack.last
        in [:stack, :swap]
          @stack[-1], @stack[-2] = @stack[-2], @stack[-1]
        in [:stack, :pop]
          @stack.pop
        in [:calc, :add]
          @stack.push @stack.pop + @stack.pop
        in [:calc, :sub]
          @stack.push @stack.pop - @stack.pop
        in [:calc, :multi]
          @stack.push @stack.pop * @stack.pop
        in [:calc, :div]
          @stack.push @stack.pop / @stack.pop
        in [:calc, :mod]
          @stack.push @stack.pop % @stack.pop
        in [:heap, :save]
          val = @stack.pop
          addr = @stack.pop
          @heap[addr] = val
        in [:heap, :load]
          addr = @stack.pop
          @stack.push @heap[addr]
        in [:flow, :def, label]
          # does nothing
        in [:flow, :call, label]
          raise "unknwon label:#{label}" unless @labels.key?(label)
          @call_stack.push @index
          @index = @labels[label]
        in [:flow, :jump, label]
          raise "unknwon label:#{label}" unless @labels.key?(label)
          @index = @labels[label]
        in [:flow, :jump_if_zero, label]
          @index = @labels[label] if @stack.pop == 0
        in [:flow, :jump_if_neg, label]
          @index = @labels[label] if @stack.pop < 0
        in [:flow, :end]
          @index = @call_stack.pop
        in [:flow, :exit]
          return
        in [:io, :write_char]
          @output.write @stack.pop.chr
        in [:io, :write_num]
          @output.write @stack.pop.to_s
        in [:io, :read_char]
          addr = @stack.pop
          @heap[addr] = @input.read(1).ord
        in [:io, :read_num]
          addr = @stack.pop
          @heap[addr] = @input.readline.to_i
        end
        @index += 1
      end
    end

    def prepare_label
      @commands.each.with_index do |command, index|
        case command
        in [:flow, :def, label]
          @labels[label] = index - 1
        else
          # skip
        end
      end
    end
  end
end
