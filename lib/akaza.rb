require "akaza/version"
if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('2.6')
  require 'akaza/ast_ext'
  require 'akaza/annotation'
end
require 'akaza/parser'
require 'akaza/vm'

module Akaza
  def self.eval(code, input: $stdin, output: $stdout)
    commands = Parser.parse(code)
    VM.new(commands, input, output).eval
  end
end
