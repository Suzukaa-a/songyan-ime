function fixture(input, segment, env)
  if input == "ab" then
    local converter = Opencc("s2t.json")
    yield(Candidate("fixture", segment.start, segment._end, converter:convert("汉语"), ""))
  end
end
