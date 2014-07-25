#!/usr/bin/env ruby
require 'curb'
require 'json'
require 'optparse'
require 'time_ago_in_words'
require 'time'
require 'digest'
require 'fileutils'

class MilestoneResult
  attr_accessor :applicable, :frameWhenAchieved, :complete
end

class FixedMilestoneResult < MilestoneResult
  def initialize(frameWhenAchieved)
      @applicable = true
      @complete = true
      @frameWhenAchieved = frameWhenAchieved
  end
end

class ArmyBasedMilestoneResult < MilestoneResult
  def initialize(achievedYet, frameNow)
    @applicable = true
    if achievedYet
      @complete = true
      @frameWhenAchieved = frameNow
    else
      @complete = false
      @frameWhenAchieved = nil
    end
  end
end

class MilestoneNotApplicableResult < MilestoneResult
  def initialize
    @applicable = false
    @complete = false
  end
end

def debug(message)
#  $stderr.puts message
end

def minutes_to_display(minutes)
  if minutes < 0
    return "-" + minutes_to_display(-1 * minutes)
  end
  minutes.to_i.to_s + ':' + ('%02i' % (60 * minutes.modulo(1)))
end

def seconds_to_display(seconds)
  minutes_to_display(seconds / 60.0)
end

def frames_to_display(frames, subzero_permitted=false)
  if frames.nil?
    "never"
  elsif frames <= 0 and !subzero_permitted
    "never"
  else
    minutes_to_display(frames / (16.0 * 60.0))
  end
end

def cache_key(url)
  Digest::hexencode(Digest::SHA256.digest(url))
end

def cache_dir
  '/tmp/dork_cache'
end

def cache_path_for_url(url)
  cache_path = cache_dir + '/' + cache_key(url)
end

def retrieve_from_url_and_cache(url)
  url_string = Curl::Easy.perform(url).body_str
  cache_path = cache_path_for_url(url)
  FileUtils::mkdir_p cache_dir
  File.write(cache_path, url_string)
  url_string
end

def retrieve_from_cache(url)
  cache_path = cache_path_for_url(url)
  begin
    url_string = File.read(cache_path)
  rescue Exception => e
    debug "cache file for #{url} not found, exception was #{e}"
    url_string = nil
  end
  url_string
end

def retrieve_json(url, cache_preferred=true)
  debug "Retrieving #{url}"
  if cache_preferred
    begin
      url_string = retrieve_from_cache(url)
    rescue Exception => e
      debug "#{url} not found in cache, falling back to network. Exception was #{e}"
    end
    url_string ||= retrieve_from_url_and_cache(url)
  else
    begin
      url_string = retrieve_from_url_and_cache(url)
    rescue Exception => e
      debug "#{url} not found on network, falling back to cache. Exception was #{e}"
    end
    url_string ||= retrieve_from_cache(url)
  end
  if url_string.nil?
    debug "Couldnt get anything from #{url}, cache_preferred = #{cache_preferred}."
  else
    begin
      json_result = JSON.parse(url_string)
    rescue Exception => e
      debug "Error while trying to parse result from #{url}: #{e}"
    end
  end
  json_result
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
  [ "First scout command", 1, 13,
    Proc.new{|match, now|
      FixedMilestoneResult.new(match["first_scout_command_frame"])
      }],
  [ "Second base started", 3, 41,
    Proc.new{|match, now|
      FixedMilestoneResult.new(match["second_base"])
      }],
  [ "22 probes                   ", 4, 17,
    Proc.new{|match, now|
      army = match["army"]
      ArmyBasedMilestoneResult.new(army["probe"] >= 22.0, now)
    }],
  [ "6 sentries, zealot, stalker ", 7, 53,
    Proc.new{|match, now|
      army = match["army"]
      ArmyBasedMilestoneResult.new(army["stalker"] >= 1.0 && army["zealot"] >= 1.0 && army["sentry"] >= 6.0, now)
    }],
  [ "44 probes                   ", 7, 56,
    Proc.new{|match, now|
      army = match["army"]
      ArmyBasedMilestoneResult.new(army["probe"] >= 44.0, now)
    }],
  [ "Third base started", 8, 8,
    Proc.new{|match, now|
      if match['duration_seconds'] < BASE_BUILD_SECONDS + (8 * 60) + 8
        MilestoneNotApplicableResult.new()
      else
        FixedMilestoneResult.new(match["third_base"])
      end
    }],
  [ "Harass enemy", 9, 1,
    Proc.new{|match, now|
      FixedMilestoneResult.new(match["first_aggressive_frame"])
    }],
  [ "+1 attack complete", 9, 49,
    Proc.new{|match, now|
      weapons = match['our_upgrades'].find{|upgrade| upgrade[0] == 'ProtossGroundWeaponsLevel1'}
      if weapons.nil?
        nil
      else
        FixedMilestoneResult.new(weapons[1])
      end
    }],
  [ "66 probes                   ", 10, 55,
    Proc.new{|match, now|
      army = match["army"]
      ArmyBasedMilestoneResult.new(army["probe"] >= 66.0, now)
    }],
  [ "+2 attack complete", 13, 4,
    Proc.new{|match, now|
      weapons = match['our_upgrades'].find{|upgrade| upgrade[0] == 'ProtossGroundWeaponsLevel2'}
      if weapons.nil?
        nil
      else
        FixedMilestoneResult.new(weapons[1])
      end
    }],
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

def analyze_match(the_match, milestone_achieved_counter, milestone_applicable_counter)

  entities = the_match['entities']
  if $player_id
    our_entity = entities.select{|entity| entity['identity']['id'] == $player_id}[0]
  else
    our_entity = entities.select{|entity| entity['race'] == 'P'}[0]
  end
  if our_entity.nil?
    puts "Hmm, doesn't look like there was a Protoss player in match ##{the_match['id']}"
    exit
  end
  $player_id = our_entity['identity']['id']
  enemy_entity = entities.reject{|entity| entity == our_entity}[0]

  # get match blob
  matchblob = retrieve_json($ggtracker_blob_url_prefix + "#{the_match['id']}")

  # get our base start times
  #
  # TODO fix this to actually look at the base start time rather than
  # working backward from when it was completed.
  #
  # Because sometimes bases are destroyed before complete, or the game
  # ends.  But the benchmark is supposed to be the base *start* time.
  #
  our_base_lives = matchblob['num_bases'].select{|part| part[0] == $player_id}[0][1]
  ets = expansion_times(our_base_lives)
  ets = ets.map{|et| [0, et - BASE_BUILD_FRAMES].max}
  the_match['second_base'] = ets[0]
  the_match['third_base'] = ets[1]

  # get harass-third time
  aggressions = matchblob['aggressions']
  if aggressions.nil?
    puts "Please re-upload this replay to GGTracker to get information about aggression/harassment."
    # TODO make aggression not-applicable
    first_aggressive_frame = 0
  else
    our_aggression = aggressions[$player_id.to_s]
#    our_aggression.each{|snapshot|
#      puts "#{frames_to_display(snapshot[0])}: #{snapshot}"
#    }
    first_aggressive_snapshot = our_aggression.find{|snapshot| snapshot[2] > 1000 || snapshot[1] > 1000}
    if first_aggressive_snapshot.nil?
      first_aggressive_frame = 0
    else
      first_aggressive_frame = first_aggressive_snapshot[0]
    end
  end
  the_match['first_aggressive_frame'] = first_aggressive_frame

  

  # get scouting time
  scouting_info = matchblob['scouting']
  if scouting_info.nil?
    puts "Please re-upload this replay to GGTracker get information about scouting."
    # TODO make scouting not-applicable
    first_scout_command_frame = 0
  else
    first_scout_command_frame = matchblob['scouting'][$player_id.to_s]
  end
  the_match['first_scout_command_frame'] = first_scout_command_frame

  the_match['army'] = Hash.new(0.0)
  milestone_results = Array.new()

  # put our player's upgrades in an easy-to-get-place
  the_match['our_upgrades'] = matchblob['upgrades'][$player_id.to_s]

  # some milestones require us to walk through the birth and death of
  # each unit.  lets make a list of each of those 'events'
  the_abf = matchblob['armies_by_frame'][$player_id.to_s]
  the_events = abf_to_events(the_abf)

  # walk through them, keeping track of army as we go, checking to see
  # at each time if a milestone has been hit
  the_events.each{ |event|
    the_match['army'][event[1]] += event[2]
    MILESTONES.each_with_index{ |milestone, i|
      if milestone_results[i].nil?
        milestone_result = milestone[3].call(the_match, event[0])
        if milestone_result && (milestone_result.complete || !milestone_result.applicable)
          milestone_results[i] = milestone_result
        end
      end
    }
  }

  milestones_achieved = []

  MILESTONES.each_with_index {|milestone, i|
    goal_seconds = milestone[1] * 60 + milestone[2]
    goal_frames = goal_seconds * FRAMES_PER_SECOND
    if milestone_results[i] && !milestone_results[i].applicable
      goal_grade = "    N/A     "
    elsif the_match['duration_seconds'] < (goal_frames / FRAMES_PER_SECOND)
      goal_grade = "    N/A     "
    elsif milestone_results[i].nil? || milestone_results[i].frameWhenAchieved == 0 || milestone_results[i].frameWhenAchieved.nil? || milestone_results[i].frameWhenAchieved > goal_frames + (GOAL_SLIPPAGE_SECONDS_PERMITTED * FRAMES_PER_SECOND)
      milestone_applicable_counter[i] += 1
      goal_grade = "WORK ON THIS"
    elsif milestone_results[i].frameWhenAchieved < goal_frames - (GOAL_SLIPPAGE_SECONDS_PERMITTED * FRAMES_PER_SECOND)
      goal_grade = "  TOO FAST  "
      milestone_applicable_counter[i] += 1
      milestone_achieved_counter[i] += 1
    else
      goal_grade = "   GOOD     "
      milestone_applicable_counter[i] += 1
      milestone_achieved_counter[i] += 1
    end

    milestones_achieved <<
    [
     milestone[0],
     milestone_results[i].nil? ? nil : milestone_results[i].frameWhenAchieved,
     goal_frames, goal_grade
    ]
  }

  # show milestones_achieved in the order that the player achieved them
  milestones_achieved.sort! { |a,b|
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

  puts "%-30s %s" % ["Played", Time.parse(the_match['ended_at']).ago_in_words]
  puts "%-30s %s" % ["Map", the_match['map_name']]
  puts "%-30s %s" % ["Enemy", "#{describe_enemy(enemy_entity)}"]
  milestones_achieved.each {|milestone_achieved|
    puts "%-30s %5s %12s (goal: %5s)" % [milestone_achieved[0], frames_to_display(milestone_achieved[1]), milestone_achieved[3], frames_to_display(milestone_achieved[2])]
  }

  puts "%-30s %s" % ["Game over", seconds_to_display(the_match['duration_seconds'])]
  puts "%-30s %s" % ["Result", our_entity['win'] ? 'VICTORY' : 'DEFEAT']
  puts "%-30s %s" % ["Match", "http://ggtracker.com/matches/#{the_match['id']}"]
end




# ====================
# main program
# ====================


$ggtracker_api_url_prefix = "http://api.ggtracker.com/api/v1/"
$ggtracker_blob_url_prefix = "https://gg2-matchblobs-prod.s3.amazonaws.com/"

$num_to_show = 1

OptionParser.new do |o|
  o.on('-m GGTRACKER_MATCH_ID') { |match_id| $match_id = match_id.to_i }
  o.on('-p GGTRACKER_PLAYER_ID') { |player_id| $player_id = player_id.to_i }
  o.on('-a') { |anyrace| $anyrace = anyrace }
  o.on('-n num_to_show') { |num_to_show| $num_to_show = num_to_show.to_i }
  o.on('-d') {
    $ggtracker_api_url_prefix = "http://localhost:9292/api/v1/"
    $ggtracker_blob_url_prefix = "https://gg2-matchblobs-dev.s3.amazonaws.com/"
  }
  o.on('-h') { puts o; exit }
  o.parse!
end
if $player_id.nil? == $match_id.nil?
  $stderr.puts "Usage: dorkshrine.rb [-p <player_id> [-n num_to_show] | -m <match_id>]"
  exit
end

# for each benchmark track how many times you got at least a good

milestone_achieved_counter = Array.new(MILESTONES.count, 0)
milestone_applicable_counter = Array.new(MILESTONES.count, 0)

if $match_id.nil?
  if $anyrace
    matches = retrieve_json($ggtracker_api_url_prefix + "matches?game_type=1v1&identity_id=#{$player_id}&page=1&paginate=true&game_type=1v1&limit=#{$num_to_show}", false)
  else
    # get latest PvZ for the indicated player
    matches = retrieve_json($ggtracker_api_url_prefix + "matches?game_type=1v1&identity_id=#{$player_id}&page=1&paginate=true&race=protoss&vs_race=zerg&game_type=1v1&limit=#{$num_to_show}", false)
  end
  matches["collection"].each {|match|
    analyze_match(match, milestone_achieved_counter, milestone_applicable_counter)
    puts ""
  }
else
  the_match = retrieve_json($ggtracker_api_url_prefix + "/matches/#{$match_id}.json")
  analyze_match(the_match, milestone_achieved_counter, milestone_applicable_counter)
end

if $num_to_show > 1
  puts "SUMMARY"
  puts "-------"
  MILESTONES.each_with_index {|milestone, i|
    puts "%-30s %3.0f%%    (%i/%i)" % [milestone[0], 100.0 * milestone_achieved_counter[i] / milestone_applicable_counter[i], milestone_achieved_counter[i], milestone_applicable_counter[i]]
  }
end
