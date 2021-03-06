#!/usr/bin/env ruby

'''
A simple script to break-up a large rectangular geographic area into smaller 25-mile square bounding boxes.
    * All lat/longs are in decimal degrees.
    * Code starts with the southwest corner.  Marches east, then moves up a row and repeats.
    * By default, produces a set of JSON bounding boxes: bounding_box:[west_long south_lat east_long north_lat].
    * Optionally, it can produce a simple format for direct entry into the Gnip Dashboard.

    Command-line arguments:
    [] west, south, east, north, tag, filepath, limit_lat, limit_long, dashboard

'''

include Math
require 'json'
require 'optparse'
require 'ostruct' #Playing with OpenStructs, a (Python) tuple sort of hash.  Slower performance
                  #than a plain o Struct, but a handy 'on the fly' data structure.

'''
#Colorado
-w -109 -e -102 -n 41 -s 37 -t "Geo-Colorado" -f "./colorado-boxes.json"
#NW Colorado
-w -106 -e -102 -n 41 -s 39 -t "geo-colorado-nw" -f "./colorado-nw-boxes.json"
#Kenya
-w 33.78 -e 42 -n 5.1 -s 4.8 -f "./kenya_geo.json"
'''

class BoundingBoxes

  PI = Math::PI
  EARTH_RADIUS_MI = 3963.1900

  def self.deg2Rad(degree)
      degree * PI / 180
  end


  def self.distance_in_mile(pt1, pt2)
      return self.distance_in_radius(pt1,pt2) * EARTH_RADIUS_MI
  end

  def self.distance_in_radius(pt1, pt2)

      dlat = deg2Rad(pt2.south - pt1.south)
      dlong = deg2Rad(pt2.west - pt1.west)

      a = sin(dlat/2)**2 +
          cos(deg2Rad(pt1.south)) * cos(deg2Rad(pt2.south)) *
              sin(dlong/2)**2
      c = 2 * atan2(sqrt(a),sqrt(1-a))

      return c
  end

  def self.resizeBox(long_offset, west, south)
      point1 = OpenStruct.new
      point2 = OpenStruct.new

      point1.west =  west
      point1.south = south
      point2.west = west + long_offset
      point2.south = south

      distance = distance_in_mile(point1,point2)

      p "distance: #{distance}"

      if distance > 24.8 and distance <= 24.9 then
          long_offset
      else
          if distance < 24.8 then
              #These latitude driven tweaks are 100% empirical for handle boxes near the Poles.
              if south.abs < 75 then
                  long_offset = long_offset + 0.0001
              elsif south.abs < 85 then
                  long_offset = long_offset + 0.001
              else
                  long_offset = long_offset + 0.01
              end
          end
          if distance > 24.9 then
              #These latitude driven tweaks are 100% empirical for handle boxes near the Poles.
              if south.abs < 75 then
                  long_offset = long_offset - 0.0001
              elsif south.abs < 85 then
                  long_offset = long_offset - 0.001
              else
                  long_offset = long_offset - 0.01
              end
          end
          resizeBox(long_offset, point1.west, point1.south)
      end
  end

  #TODO: move to OptionParser class -------------------
  #Parse command-line and set variables.
  OptionParser.new do |o|
    o.on('-w WEST') { |west| $west = west }
    o.on('-e EAST') { |east| $east = east }
    o.on('-n NORTH') { |north| $north = north }
    o.on('-s SOUTH') { |south| $south = south }
    o.on('-t TAG') { |tag| $tag = tag}
    o.on('-la LIMIT_LAT') { |limit_lat| $limit_lat = limit_lat}
    o.on('-lo LIMIT_LONG') { |limit_long| $limit_long = limit_long}
    o.on('-f FILEPATH') { |filepath| $filepath = filepath}
    o.on('-d') { $dashboard = true}
    o.on('-h') {puts o; exit}
    o.parse!
  end

  sa = OpenStruct.new
  sa.west = $west.to_f
  sa.east = $east.to_f
  sa.north = $north.to_f
  sa.south = $south.to_f
  tag = $tag
  filepath = $filepath

  #dashboard provides an option to output the bounding boxes as simple text for copy/paste into Gnip dashboard.
  if $dashboard.nil? then
    dashboard = false
  else
    dashboard = true
    if filepath.nil? then
       filepath = 'geo_rules.txt'
    end
  end

  if filepath.nil? then
    filepath = 'geo_rules.json'
  end

  #Set defaults.  Most appropriate for mid-latitudes.  Tested with Continental US area...
  lat_offset_default = 0.35
  long_offset_default = 0.45

  #Make smaller near the Equator.
  if sa.north.abs < 15 or sa.south.abs < 15 then
      long_offset_default = 0.35
  end

  #Make larger near the Poles.
  if sa.north.abs > 80 or sa.south.abs > 80 then
      long_offset_default = 3  #Purely an empirical number!
  end

  offset = OpenStruct.new
  if $limit_lat.nil? then
    offset.lat = lat_offset_default
  else
     offset.lat = $limit_lat.to_f
  end

  if $limit_long.nil? then
    offset.long = long_offset_default
  else
    offset.long = $limit_long.to_f
  end
  # end of appOptionParser class.

  #Determine the number of boxes to build.
  #How many columns needed to transverse West-East distance?
  columns = (sa.west - sa.east).abs/offset.long
  columns = columns.ceil
  #How many rows needed to transverse North-South distance?
  rows = (sa.north - sa.south)/offset.lat
  rows = rows.ceil

  p 'Expecting ' + (columns * rows).to_s + ' boxes (' + rows.to_s + ' rows X ' + columns.to_s + ' columns).'

  boxes = Array.new    #Create an array to hold boxes.  #Ruby lists are like a stack, with push and pop

  #Initialize Origin bounding box
  #Create a point 'origin' object.
  box = OpenStruct.new
  box.west = sa.west
  box.east = sa.west + offset.long
  box.south = sa.south
  box.north = sa.south + offset.lat

  #Walk the study area building bounding boxes.
  # Starting in SW corner, marching east, then up a row and repeat.
  while box.south < sa.north #marching northward until next row would be completely out of study area.
    while box.west < sa.east  #marching eastward, building row of boxes

      #Create bounding box. #bounding_box:[west_long south_lat east_long north_lat]

      box_temp = OpenStruct.new  #Create a new object, otherwise every boxes[] element points to current object.
      box_temp.west = box.west
      box_temp.east = box.east
      box_temp.south = box.south
      box_temp.north = box.north

      #Check if northern and eastern edges extend beyond study area and snap back if necessary.
      if box_temp.north > sa.north then
          box_temp.north = sa.north
      end
      if box_temp.east > sa.east then
          box_temp.east = sa.east
      end

      boxes << box_temp

      #Advance eastward.
      box.west = (box.west + offset.long)
      box.east = (box.east + offset.long)
    end

    #Snap back to western edge.
    box.west = sa.west

    #Resize bounding box w.r.t. longitude offset...
    offset.long = self.resizeBox(offset.long, box.west, box.south)

    #Advance eastward, using new longitude offset.
    box.east = box.west + offset.long

    #Advance northward.
    box.south = (box.south + offset.lat).round(8)
    box.north = (box.north + offset.lat).round(8)

  end



  #Write output. Convert 'boxes' list top list of bounding_box rules

  if not dashboard then
    rules = []
    for box in boxes do

      #p "longitude coordinates: #{box.west}  #{box.east}"

      rule_syntax = "bounding_box:[#{"%3.5f" % box.west} #{"%3.5f" % box.south} #{"%3.5f" % box.east} #{"%3.5f" % box.north}]"
      #p rule_syntax
      if tag == nil then
        rule = {'value' => rule_syntax}
      else
        rule = {'value' => rule_syntax, 'tag' => tag}
      end
      rules.push rule
    end

    rule_set = Hash.new
    rule_set['rules'] = rules

    File.open(filepath,'w') do |f|
      f.write(rule_set.to_json)
    end

    #p rule_set.to_json
  else
    contents = ""
    for box in boxes do

      p "longitude coordinates: #{box.west}  #{box.east}"

      rule_syntax = "bounding_box:[#{"%3.5f" % box.west} #{"%3.5f" % box.south} #{"%3.5f" % box.east} #{"%3.5f" % box.north}]"
      contents = contents + rule_syntax + "\n"
    end
    File.open(filepath,'w') do |f|
      f.write(contents)
    end

  end

end


