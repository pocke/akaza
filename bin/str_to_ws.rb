# Convert string to Whitespace program that outputs the string.

def main(str)
  res = +""
  str.chars.each do |ch|
    res << "   #{ch.ord.to_s(2).gsub('1', "\t").gsub('0', ' ')}\n"
    res << "	\n  "
  end
  res << "\n\n\n"
end

puts main ARGV[0]
