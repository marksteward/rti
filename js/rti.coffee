assertEqual = (tested, expected, errorMessage) ->
  throw "Failed assertion: #{errorMessage}" if tested isnt expected

class RTI

  constructor: (@dataStream) ->

  parse: (completionHandler) =>
    @parseHSH()
    completionHandler()

  # Returns the index of an element in the HSHImage float array given the following arguments,
  # h - y position of the current pixel
  # w - x position of the current pixel
  # b - the current color channel
  # o - the current term (keep in mind there are order*order terms)

  getIndex: (h, w, b, o) ->
    h * (@width * @bands * @order * @order) + w * (@bands * @order * @order) + b * (@order * @order) + o

  # Returns a float array containing the entire RTI coefficient set. The order of elements in the float array is,
  # rtiheight*rtiwidth*bands*terms
  # (where terms = (order*order), for other variables check the comments above)

  # RTI file info : These variables are initialize in the loadHSH function
  # rtiwidth, rtiheight - Height and width of the loaded RTI
  # bands - Number of color channels in the image, usually 3
  # order - The order of the RTI reflectance model. The actual number of coefficients (i.e. terms) = order * order

  parseHSH: ->
    # strip all lines beginning with #; (used ifstream::infile.peek)
    @dataStream.readLine() while @dataStream.peekLine()[0] is '#'

    @file_type     = Number @dataStream.readLine()

    header_line_2  = @dataStream.readLine().split(" ")
    header_line_3  = @dataStream.readLine().split(" ")
    @width         = Number header_line_2[0]
    @height        = Number header_line_2[1]
    @bands         = Number header_line_2[2]
    @terms         = Number header_line_3[0]
    @basis_type    = Number header_line_3[1]
    @element_size  = Number header_line_3[2]

    console.log "Dimensions:   #{@width} x #{@height}"
    console.log "Bands:        #{@bands}"
    console.log "Terms:        #{@terms}"
    console.log "Basis Type:   #{@basis_type}"
    console.log "Element Size: #{@element_size}"

    assertEqual(@file_type, 3, "Cannot parse non-HSH file type #{@file_type}")

    @order = Math.sqrt(@terms)
    @coefficients = new Uint8Array(@width * @height * @bands * @terms)

    # Read the scale values
    @scale = new Float32Array(@terms)
    @scale[i] = @dataStream.readFloat() for i in [0...@terms]

    # Read the bias values
    @bias  = new Float32Array(@terms)
    @bias[i] = @dataStream.readFloat() for i in [0...@terms]

    # Read the main data block
    for y in [0...@height]
      for x in [0...@width]
        for b in [0...@bands]
          for t in [0...@terms]
            @coefficients[@getIndex(y, x, b, t)] = @dataStream.readUint8()
            # OpenGL ordering (i.e. flip-Y)
            # @hshpixels[@getIndex(@height-1-y, x, b, t)] = value

  # Render into an RGBA array and return it
  # lx, ly, lz are the global light position
  # // Renders an image under the current lighting position as specified by global variables lx, ly and lz
  # // The HSHImage float array is passed as input, and an image with (bands) color channels is returned as the output

  # Compute weights based on the lighting direction
  computeWeights: (theta, phi) ->

    weights = new Float32Array(16)

    phi = phi + (2 * PI) if phi < 0

    weights[0]  = 1/sqrt(2*PI)
    weights[1]  = sqrt(6/PI)      * (cos(phi)*sqrt(cos(theta)-cos(theta)*cos(theta)))
    weights[2]  = sqrt(3/(2*PI))  * (-1 + 2*cos(theta))
    weights[3]  = sqrt(6/PI)      * (sqrt(cos(theta) - cos(theta)*cos(theta))*sin(phi))

    weights[4]  = sqrt(30/PI)     * (cos(2*phi)*(-cos(theta) + cos(theta)*cos(theta)))
    weights[5]  = sqrt(30/PI)     * (cos(phi)*(-1 + 2*cos(theta))*sqrt(cos(theta) - cos(theta)*cos(theta)))
    weights[6]  = sqrt(5/(2*PI))  * (1 - 6*cos(theta) + 6*cos(theta)*cos(theta))
    weights[7]  = sqrt(30/PI)     * ((-1 + 2*cos(theta))*sqrt(cos(theta) - cos(theta)*cos(theta))*sin(phi))
    weights[8]  = sqrt(30/PI)     * ((-cos(theta) + cos(theta)*cos(theta))*sin(2*phi))

    weights[9]  = 2*sqrt(35/PI)   * cos(3*phi)*pow(cos(theta) - cos(theta)*cos(theta),(3/2))
    weights[10] = (sqrt(210/PI)   * cos(2*phi)*(-1 + 2*cos(theta))*(-cos(theta) + cos(theta)*cos(theta)))
    weights[11] = 2*sqrt(21/PI)   * cos(phi)*sqrt(cos(theta) - cos(theta)*cos(theta))*(1 - 5*cos(theta) + 5*cos(theta)*cos(theta))
    weights[12] = sqrt(7/(2*PI))  * (-1 + 12*cos(theta) - 30*cos(theta)*cos(theta) + 20*cos(theta)*cos(theta)*cos(theta))
    weights[13] = 2*sqrt(21/PI)   * sqrt(cos(theta) - cos(theta)*cos(theta))*(1 - 5*cos(theta) + 5*cos(theta)*cos(theta))*sin(phi)
    weights[14] = (sqrt(210/PI)   * (-1 + 2*cos(theta))*(-cos(theta) + cos(theta)*cos(theta))*sin(2*phi))
    weights[15] = 2*sqrt(35/PI)   * pow(cos(theta) - cos(theta)*cos(theta),(3/2))*sin(3*phi)

    return weights


  renderImageHSH: (context, lx, ly, lz) ->

    sCoord = @cartesianToSpherical(lx, ly, lz)
    weights = @computeWeights(sCoord.theta, sCoord.phi)

    console.log "Rendering:    #{@width} x #{@height}"
    console.log "(lx, ly, lz): (#{lx}, #{ly}, #{lz})"
    console.log "Context:      #{context}"

    context.clearRect(0, 0, @width, @height)
    imagePixelData = context.createImageData(@width, @height)
    outputBands = 4 # we are going to emit RGBA, not RGB

    clamp = (value) ->
      max(min(value, 1.0), 0.0)

    for j in [0...@height]
      for i in [0...@width]
        # The computation for a single pixel
        for b in [0...@bands]
          # The computation for a single color channel on a single pixel
          value = 0.0
          # Multiply and sum the coefficients with the weights.
          # This evaluates the polynomial function we use for lighting
          for t in [0...(@terms)]
            value += ((@coefficients[@getIndex(j,i,b,t)] / 255) * @scale[t] + @bias[t]) * weights[t]
          value = clamp(value)
          # Set the computed pixel color for that pixel, color channel
          imagePixelData.data[j*@width*outputBands+i*outputBands+b] = value * 255
        # Set the alpha channel
        imagePixelData.data[(j*@width*outputBands) + (i*outputBands) + 3] = 255

    window.imagePixelData = imagePixelData
    context.putImageData(imagePixelData, 0, 0)

  makeTextures: ->
    textures = {}
    for term in [0...@terms]
      textureData = new Uint8Array(@width * @height * @bands)
      i = 0
      for y in [0...@height]
        for x in [0...@width]
          for channel in [0...@bands]
            textureData[i] = @coefficients[@getIndex(y,x,channel,term)]
            i += 1
      textures[term] = textureData
    return textures

window.go = ->
  canvas = $('#rgbtexture > canvas')[0]
  window.drawContext = canvas.getContext('2d')

  console.log "Parsing RTI file..."
  rti.parseHSH()
  console.log "Parsed."

  canvas.width = rti.width
  canvas.height = rti.height

  moveHandler = (event) =>
    canvasOffset = $(canvas).offset()
    x = event.clientX + Math.floor(canvasOffset.left)
    y = event.clientY + Math.floor(canvasOffset.top) + 1

    x -= canvas.width / 2
    y *= -1
    y += canvas.height / 2

    # TODO: this is slightly wrong
    console.log "clicked at", x, y

    min_axis = Math.min(canvas.width, canvas.height) / 2
    console.log "min_axis", min_axis

    theta = Math.atan2(y, x)
    r     = Math.min(Math.sqrt(x*x + y*y), min_axis) / min_axis # Clamp to radius of circle = min_axis
    lx    = r * Math.cos(theta)
    ly    = r * Math.sin(theta)
    lz    = Math.sqrt(1.0*1.0 - (lx*lx) - (ly*ly))

    console.log "theta, r, lx, ly", theta, r, lx, ly
    window.draw(lx, ly, lz)

  $('#rgbtexture > canvas').mousemove(moveHandler)

window.drawS = (theta, phi) ->
  x = Math.cos(theta) * Math.sin(phi)
  y = Math.sin(theta) * Math.sin(phi)
  z = Math.cos(phi)
  console.log "Drawing: (#{x}, #{y}, #{z})"
  window.draw(x, y, z)

window.draw = ( x, y, z) ->
  rti.renderImageHSH(window.drawContext, x, y, z)

window.assertEqual = assertEqual

window.jdc ?= {}
window.jdc.RTI = RTI
