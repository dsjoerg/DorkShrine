#!/usr/bin/env ruby
require 'curb'
require 'json'
require 'optparse'

def minutes_to_display(minutes)
  minutes.to_i.to_s + ':' + ('%02i' % (60 * minutes.modulo(1)))
end

def seconds_to_display(seconds)
  minutes_to_display(seconds / 60.0)
end

def frames_to_display(frames)
  if frames.nil?
    "never"
  elsif frames <= 0
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

def describe_enemy(entity)
  if (entity['identity']['bnet_id'].to_i == 0)
    controller = entity['identity']['name']
  else
    controller = "Human"
  end
  "#{controller} #{race_name(entity['race'])}"
end

# from ./dorkshrine.rb -m 5116849
MILESTONES = [
  [ "22 probes                   ", 4, 17,
    Proc.new{|army|
      army["probe"] >= 22.0
    }],
  [ "6 sentries, zealot, stalker ", 7, 53,
    Proc.new{|army|
      army["stalker"] >= 1.0 && army["zealot"] >= 1.0 && army["sentry"] >= 6.0
    }],
  [ "44 probes                   ", 7, 56,
    Proc.new{|army|
      army["probe"] >= 44.0
    }],
  [ "66 probes                   ", 10, 55,
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

FRAMES_PER_SECOND = 16
GOAL_SLIPPAGE_SECONDS_PERMITTED = 30
BASE_BUILD_FRAMES = 100 * FRAMES_PER_SECOND

def analyze_match(the_match)

  entities = the_match['entities']
  our_entity = entities.select{|entity| entity['race'] == 'P'}[0]
  if our_entity.nil?
    puts "Hmm, doesn't look like there was a Protoss player in match ##{the_match['id']}"
    exit
  end
  $player_id = our_entity['identity']['id']
  enemy_entity = entities.reject{|entity| entity['race'] == 'P'}[0]

  # get base start times
  http_result = Curl::Easy.perform("https://gg2-matchblobs-prod.s3.amazonaws.com/#{the_match['id']}")
  json_result = http_result.body_str
  matchblob = JSON.parse(json_result)
  our_base_lives = matchblob['num_bases'].select{|part| part[0] == $player_id}[0][1]
  ets = expansion_times(our_base_lives)
  ets = ets.map{|et| [0, et - BASE_BUILD_FRAMES].max}

  # get scouting time
  scouting_info = matchblob['scouting']
  if scouting_info.nil?
    puts "Please re-upload this replay to GGTracker get information about scouting."
    first_scout_command_frame = 0
  else
    first_scout_command_frame = matchblob['scouting'][$player_id.to_s]
  end

  # get time at which we have 6 sentries, zealot, and a stalker
  the_abf = matchblob['armies_by_frame'][$player_id.to_s]
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
                ["Second base started", ets[0],        3, 41],
                ["Third base started", ets[1],        8, 8],
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
  benchmarks.sort! { |a,b|
    a_time = a[1]
    b_time = b[1]
    if a_time.nil? || a_time == 0
      a_time = 1000000
    end
    if b_time.nil? || b_time == 0
      b_time = 1000000
    end
    a_time <=> b_time
  }

  puts "%-30s %s" % ["Map", the_match['map_name']]
  puts "%-30s %s" % ["Enemy", "#{describe_enemy(enemy_entity)}"]
  benchmarks.each {|benchmark|
    goal_seconds = benchmark[2] * 60 + benchmark[3]
    goal_frames = goal_seconds * FRAMES_PER_SECOND
    if benchmark[1].nil? || benchmark[1] == 0 || benchmark[1] > goal_frames + (GOAL_SLIPPAGE_SECONDS_PERMITTED * FRAMES_PER_SECOND)
      goal_grade = "WORK ON THIS"
    elsif benchmark[1] >= goal_frames
      goal_grade = "   GOOD!    "
    else
      goal_grade = "  GREAT!    "
    end
    puts "%-30s %5s %12s (goal: %5s)" % [benchmark[0], frames_to_display(benchmark[1]), goal_grade, frames_to_display(goal_frames)]
  }

  puts "%-30s %s" % ["Game over", seconds_to_display(the_match['duration_seconds'])]
  puts "%-30s %s" % ["Result", our_entity['win'] ? 'VICTORY' : 'DEFEAT']
  puts "%-30s %s" % ["Match", "http://ggtracker.com/matches/#{the_match['id']}"]
end



$num_to_show = 1

OptionParser.new do |o|
  o.on('-m GGTRACKER_MATCH_ID') { |match_id| $match_id = match_id.to_i }
  o.on('-p GGTRACKER_PLAYER_ID') { |player_id| $player_id = player_id.to_i }
  o.on('-n num_to_show') { |num_to_show| $num_to_show = num_to_show.to_i }
  o.on('-h') { puts o; exit }
  o.parse!
end
if $player_id.nil? == $match_id.nil?
  $stderr.puts "Usage: dorkshrine.rb [-p <player_id> [-n num_to_show] | -m <match_id>]"
  exit
end

if $match_id.nil?
  # get latest PvZ for the indicated player
  matches = json_from_url("http://api.ggtracker.com/api/v1/matches?game_type=1v1&identity_id=#{$player_id}&page=1&paginate=true&race=protoss&game_type=1v1&limit=#{$num_to_show}")
  matches["collection"].each {|match|
    analyze_match(match)
    puts ""
  }
else
  the_match = json_from_url("http://api.ggtracker.com/api/v1/matches/#{$match_id}.json")
  analyze_match(the_match)
end
