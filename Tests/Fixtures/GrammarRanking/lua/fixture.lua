return function(input, segment, env)
  if input == "ab" then
    local converter = assert(Opencc("s2t.json"))
    yield(Candidate("fixture", segment.start, segment._end, converter:convert("汉语"), ""))
  end
end
