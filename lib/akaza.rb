require "akaza/version"
require 'akaza/ast_ext'
require 'akaza/annotation'
require 'akaza/parser'
require 'akaza/vm'

module Akaza
  def self.eval(code, input: $stdin, output: $stdout)
    commands = Parser.parse(code)
    VM.new(commands, input, output).eval
  end
end
