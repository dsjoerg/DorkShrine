DorkShrine
==========

A fun program to tell you how well you executed a [specific PvZ build](http://ggtracker.com/matches/5116849) that FlatlineSC2 showed me.

It uses the GGTracker API.  Someday it will do more stuff!


First Things First
------------------

`bundle install`



Examples
--------

Give it a GGTracker match ID.

```
> bundle exec ./dorkshrine.rb -m 5139159

Map                            Merry Go Round LE
Enemy                          Zerg
First scout command             0:58   GREAT!     (goal:  1:12)
Second base started             3:41    GOOD!     (goal:  3:40)
Third base started              7:44   GREAT!     (goal:  8:07)
6 sentries, zealot, stalker     7:58    GOOD!     (goal:  7:53)
66 probes                      13:41 WORK ON THIS (goal: 10:54)
Game over                      22:03
Result                         VICTORY
Match                          http://ggtracker.com/matches/5139159
```

Alternatively, you can give it your GGTracker player ID and it will
show you analysis for your latest PvZ match.

```
> bundle exec ./dorkshrine.rb -p 1455

Map                            Merry Go Round LE
Enemy                          Zerg
First scout command             0:50   GREAT!     (goal:  1:12)
Second base started             3:52    GOOD!     (goal:  3:40)
6 sentries, zealot, stalker     8:30 WORK ON THIS (goal:  7:53)
Third base started             10:30 WORK ON THIS (goal:  8:07)
66 probes                      14:01 WORK ON THIS (goal: 10:54)
Game over                      36:06
Result                         DEFEAT
Match                          http://ggtracker.com/matches/5149753
```
