module Akaza
  class Parser
    EOF = Class.new(StandardError)

    SPACE = " "
    TAB = "\t"
    NL = "\n"

    def self.parse(code)
      self.new(code).parse
    end

    def initialize(code)
      @io = StringIO.new(code)
    end

    def parse
      commands = []

      loop do
        case c = nextc
        when SPACE
          commands << parse_stack
        when NL
          commands << parse_flow
        when TAB
          case nextc
          when SPACE
            commands << parse_calc
          when TAB
            commands << parse_heap
          when NL
            commands << parse_io
          end
        else
          raise "unreachable: #{c}"
        end
      rescue EOF
        return commands
      end
    end

    private def parse_stack
      case ch = nextc
      when SPACE
        [:stack, :push, nextint]
      else
        case c = [ch, nextc]
        when [NL, SPACE]
          [:stack, :dup]
        when [NL, TAB]
          [:stack, :swap]
        when [NL, NL]
          [:stack, :pop]
        else
          raise "unreachable: #{c}"
        end
      end
    end

    private def parse_flow
      case c = [nextc, nextc]
      when [SPACE, SPACE]
        [:flow, :def, nextlabel]
      when [SPACE, TAB]
        [:flow, :call, nextlabel]
      when [SPACE, NL]
        [:flow, :jump, nextlabel]
      when [TAB, SPACE]
        [:flow, :jump_if_zero, nextlabel]
      when [TAB, TAB]
        [:flow, :jump_if_neg, nextlabel]
      when [TAB, NL]
        [:flow, :end]
      when [NL, NL]
        [:flow, :exit]
      else
        raise "unreachable: #{c}"
      end
    end

    private def parse_calc
      case c = [nextc, nextc]
      when [SPACE, SPACE]
        [:calc, :add]
      when [SPACE, TAB]
        [:calc, :sub]
      when [SPACE, NL]
        [:calc, :multi]
      when [TAB, SPACE]
        [:calc, :div]
      when [TAB, TAB]
        [:calc, :mod]
      else
        raise "unreachable: #{c}"
      end
    end

    private def parse_heap
      case c = nextc
      when SPACE
        [:heap, :save]
      when TAB
        [:heap, :load]
      else
        raise "unreachable: #{c}"
      end
    end

    private def parse_io
      case c = [nextc, nextc]
      when [SPACE, SPACE]
        [:io, :write_char]
      when [SPACE, TAB]
        [:io, :write_num]
      when [TAB, SPACE]
        [:io, :read_char]
      when [TAB, TAB]
        [:io, :read_num]
      else
        raise "unreachable: #{c}"
      end
    end

    private def nextc
      case ch = @io.read(1)
      when SPACE, TAB, NL
        return ch
      when nil
        raise EOF
      else
        # comment
        nextc
      end
    end

    private def nextint
      sign = nextc
      int = +""
      while (ch = nextc) != NL
        int << ch
      end
      res = int.gsub(SPACE, '0').gsub(TAB, '1').to_i(2)
      res = 0 - res if sign == TAB
      res
    end

    private def nextlabel
      label = +""
      while (ch = nextc) != NL
        label << ch
      end
      label
    end
  end
end
