# Does what it says on the tin
assertEqual = (tested, expected, errorMessage) ->
  throw "Failed assertion: #{errorMessage}" if tested isnt expected