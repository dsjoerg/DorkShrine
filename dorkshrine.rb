#!/Users/david/.rvm/rubies/ruby-1.9.3-p429/bin/ruby

require 'curb'
require 'json'

# TODO remove DJ_IDENTITY, make it into an argument with a default of 1455
# TODO fix the first line ruby invocation
# TODO add a mode where you can specify a match ID

def minutes_to_display(minutes)
  minutes.to_i.to_s + ':' + ('%02i' % (60 * minutes.modulo(1)))
end

def seconds_to_display(seconds)
  minutes_to_display(seconds / 60.0)
end

def frames_to_display(frames)
  if frames <= 0
    "never"
  else
    minutes_to_display(frames / (16.0 * 60.0))
  end
end

def json_from_url(url)
  http_result = Curl::Easy.perform(url)
  json_result = http_result.body_str
  JSON.parse(json_result)
end

def race_name(race_char)
  return 'Zerg' if race_char == 'Z'
  return 'Protoss' if race_char == 'P'
  return 'Terran' if race_char == 'T'
  return race_char
end

# turn each unit lifetime into two events: unit born and unit died, and sort them
def abf_to_events(abf)
  events = []
  abf.each { |unit_info|
    events << [unit_info[1], unit_info[0], +1]
    events << [unit_info[2], unit_info[0], -1]
  }
  events.sort{|a,b| a[0] <=> b[0]}
end

MILESTONES = [
  [ "6 sentries, zealot, stalker ", 7, 56,
    Proc.new{|army|
      army["stalker"] >= 1.0 && army["zealot"] >= 1.0 && army["sentry"] >= 6.0
    }],
  [ "66 probes                   ", 10, 57,
    Proc.new{|army|
      army["probe"] >= 66.0
    }]
]

def expansion_times(base_lives)
  two_base_frame = 0
  three_base_frame = 0

  num_bases = 0
  events = []
  base_lives.each { |base_life|
    events << [base_life[0], +1]
    events << [base_life[1], -1]
  }
  events.sort!{|a,b| a[0] <=> b[0]}
  events.each{|event|
    num_bases += event[1]
    if two_base_frame == 0 && num_bases >= 2
      two_base_frame = event[0]
    end
    if three_base_frame == 0 && num_bases >= 3
      three_base_frame = event[0]
    end
  }
  return [two_base_frame, three_base_frame]
end

DJ_IDENTITY_ID = 1455
FRAMES_PER_SECOND = 16
GOAL_SLIPPAGE_SECONDS_PERMITTED = 30
BASE_BUILD_FRAMES = 100 * FRAMES_PER_SECOND

# get latest match ID
matches = json_from_url("http://api.ggtracker.com/api/v1/matches?category=Ladder&game_type=1v1&identity_id=#{DJ_IDENTITY_ID}&page=1&paginate=true&race=protoss&game_type=1v1")
latest_match = matches["collection"][0]

# show some basic match details
entities = latest_match['entities']
our_entity = entities.select{|entity| entity['identity']['id'] == DJ_IDENTITY_ID}[0]
enemy_entity = entities.reject{|entity| entity['identity']['id'] == DJ_IDENTITY_ID}[0]

# get base start times
http_result = Curl::Easy.perform("https://gg2-matchblobs-prod.s3.amazonaws.com/#{latest_match['id']}")
json_result = http_result.body_str
matchblob = JSON.parse(json_result)
dj_base_lives = matchblob['num_bases'].select{|part| part[0] == DJ_IDENTITY_ID}[0][1]
ets = expansion_times(dj_base_lives)
ets = ets.map{|et| et - BASE_BUILD_FRAMES}

# get scouting time
first_scout_command_frame = matchblob['scouting'][DJ_IDENTITY_ID.to_s]

# get time at which we have 6 sentries, zealot, and a stalker
the_abf = matchblob['armies_by_frame'][DJ_IDENTITY_ID.to_s]
the_events = abf_to_events(the_abf)
milestone_frames = Array.new()
the_army = Hash.new(0.0)

# walk through them, keeping track of army
the_events.each{ |event|
  the_army[event[1]] += event[2]
  MILESTONES.each_with_index{ |milestone, i|
    if milestone_frames[i].nil? && milestone[3].call(the_army)
      milestone_frames[i] = event[0]
    end
  }
}

benchmarks = [
["First scout command", first_scout_command_frame,   1, 13],
["Second base started", ets[0],        3, 42],
["Third base started", ets[1],        8, 10],
]

MILESTONES.each_with_index {|milestone, i|
  benchmarks <<
  [
   milestone[0],
   milestone_frames[i],
   milestone[1], milestone[2]
  ]
}

# show benchmarks in the order that the player achieved them
benchmarks.sort!{|a,b| a[1] <=> b[1]}

puts "%-30s %s" % ["Map", latest_match['map_name']]
puts "%-30s %s" % ["Enemy", "#{race_name(enemy_entity['race'])}"]
benchmarks.each {|benchmark|
  goal_seconds = benchmark[2] * 60 + benchmark[3]
  goal_frames = goal_seconds * FRAMES_PER_SECOND
  if benchmark[1] == 0 || benchmark[1] > goal_frames + (GOAL_SLIPPAGE_SECONDS_PERMITTED * FRAMES_PER_SECOND)
    goal_grade = "WORK ON THIS"
  elsif benchmark[1] >= goal_frames
    goal_grade = "   GOOD!    "
  else
    goal_grade = "  GREAT!    "
  end
  puts "%-30s %5s %12s (goal: %5s)" % [benchmark[0], frames_to_display(benchmark[1]), goal_grade, frames_to_display(goal_frames)]
}

puts "%-30s %s" % ["Game over", seconds_to_display(latest_match['duration_seconds'])]
puts "%-30s %s" % ["Result", our_entity['win'] ? 'VICTORY' : 'DEFEAT']
puts "%-30s %s" % ["Match", "http://ggtracker.com/matches/#{latest_match['id']}"]
