#!/usr/bin/env bash
# The edge-anchored resize actions move only the named edge and leave the opposite
# one where it is, so a positive delta always grows the window from that edge. That
# is what separates them from window-modify-width/height, which resize around the
# layout's own anchor.
#
# Stacked columns cover the height directions (the upper window must grow downward
# instead of making the whole column taller), and dwindle's splits cover the width
# directions, where the edge facing the screen is the one that has to stay put. An
# edge the layout cannot resize at all is a no-op rather than an unanchored resize.
set -euo pipefail

cat >> "$UMBRIEL_CONFIG" <<'EOF'

[animation]
duration_ms = 1
EOF
"$UMBRIEL" msg config-reload > /dev/null

spawn_client() {
  foot --title="$1" sh -c 'sleep 120' > /dev/null 2>&1 &
}

wait_for_count() {
  local want=$1 count=
  for _ in $(seq 60); do
    count=$("$UMBRIEL" windows --json | jq 'length')
    [[ $count == "$want" ]] && return 0
    sleep 0.1
  done
  echo "expected $want window(s), got $count"
  return 1
}

window_id() {
  "$UMBRIEL" windows --json | jq -r --arg t "$1" '.[] | select(.title == $t) | .id'
}

read_box() {
  "$UMBRIEL" windows --json | jq -r --arg t "$1" '.[] | select(.title == $t) | "\(.x) \(.y) \(.w) \(.h)"'
}

focus() {
  "$UMBRIEL" msg "window-focus:$(window_id "$1")" > /dev/null
}

side_by_side() {
  local out=
  for _ in $(seq 60); do
    out=$("$UMBRIEL" windows --json)
    if jq -e '
      [.[] | select(.title == "edge-one")] as $a
      | [.[] | select(.title == "edge-two")] as $b
      | ($a | length == 1) and ($b | length == 1)
        and ($a[0].x != $b[0].x) and ($a[0].y == $b[0].y)
    ' <<< "$out" > /dev/null; then
      return 0
    fi
    sleep 0.1
  done
  echo "expected two windows side by side: $out"
  return 1
}

stacked() {
  local out=
  for _ in $(seq 60); do
    out=$("$UMBRIEL" windows --json)
    if jq -e '
      [.[] | select(.title == "edge-one")] as $a
      | [.[] | select(.title == "edge-two")] as $b
      | ($a | length == 1) and ($b | length == 1)
        and ($a[0].x == $b[0].x) and ($a[0].y != $b[0].y)
    ' <<< "$out" > /dev/null; then
      return 0
    fi
    sleep 0.1
  done
  echo "expected two windows stacked in one column: $out"
  return 1
}

# --- height: the upper window of a stacked column ----------------------------

spawn_client edge-one
wait_for_count 1
spawn_client edge-two
wait_for_count 2

"$UMBRIEL" msg window-consume-or-expel-left > /dev/null
stacked

read -r _x one_y _w _h < <(read_box edge-one)
read -r _x two_y _w _h < <(read_box edge-two)
if (( one_y < two_y )); then
  upper=edge-one
  lower=edge-two
else
  upper=edge-two
  lower=edge-one
fi
echo "stacked: upper=$upper lower=$lower"

read -r _x before_upper_y _w before_upper_h < <(read_box "$upper")
read -r _x before_lower_y _w before_lower_h < <(read_box "$lower")

focus "$upper"
"$UMBRIEL" msg window-modify-height-down:0.1 > /dev/null

wait_for_height_down() {
  local out= ax ay aw ah bx by bw bh
  for _ in $(seq 60); do
    read -r ax ay aw ah < <(read_box "$upper")
    read -r bx by bw bh < <(read_box "$lower")
    if (( ay == before_upper_y && ah > before_upper_h && bh < before_lower_h && by > before_lower_y )); then
      return 0
    fi
    sleep 0.1
  done
  echo "height-down did not grow $upper downward: upper=$ax $ay $aw $ah (was y=$before_upper_y h=$before_upper_h), lower=$bx $by $bw $bh (was y=$before_lower_y h=$before_lower_h)"
  return 1
}
wait_for_height_down

read -r _x _y _w upper_after_h < <(read_box "$upper")
read -r _x _y _w lower_after_h < <(read_box "$lower")
if (( upper_after_h + lower_after_h < before_upper_h + before_lower_h - 4 \
   || upper_after_h + lower_after_h > before_upper_h + before_lower_h + 4 )); then
  echo "the stacked pair's combined height changed: $((before_upper_h + before_lower_h)) -> $((upper_after_h + lower_after_h))"
  exit 1
fi

# height-up on the lower window pins its bottom edge: y + h stays put.
read -r _x before_y _w before_h < <(read_box "$lower")
focus "$lower"
"$UMBRIEL" msg window-modify-height-up:0.1 > /dev/null

wait_for_height_up() {
  local out= x y w h
  for _ in $(seq 60); do
    read -r x y w h < <(read_box "$lower")
    if (( y < before_y && h > before_h && y + h == before_y + before_h )); then
      return 0
    fi
    sleep 0.1
  done
  echo "height-up on $lower did not pin the bottom edge: $x $y $w $h, expected y<$before_y h>$before_h y+h==$((before_y + before_h))"
  return 1
}
wait_for_height_up

# --- dwindle: each width direction pins the screen-facing edge ---------------

cat >> "$UMBRIEL_CONFIG" <<'EOF'

[layout]
mode = "dwindle"
EOF
"$UMBRIEL" msg config-reload > /dev/null
side_by_side

read -r one_x _y _w _h < <(read_box edge-one)
read -r two_x _y _w _h < <(read_box edge-two)
if (( one_x < two_x )); then
  left=edge-one
  right=edge-two
else
  left=edge-two
  right=edge-one
fi
echo "dwindle split: left=$left right=$right"

# The left window's left edge faces the screen, so dwindle owns no boundary there:
# the action must leave the geometry alone rather than resize unanchored.
read -r before_x before_y before_w before_h < <(read_box "$left")
focus "$left"
"$UMBRIEL" msg window-modify-width-left:0.1 > /dev/null
sleep 0.5
read -r after_x after_y after_w after_h < <(read_box "$left")
if [[ "$after_x $after_y $after_w $after_h" != "$before_x $before_y $before_w $before_h" ]]; then
  echo "width-left resized a screen-facing edge: $before_x $before_y $before_w $before_h -> $after_x $after_y $after_w $after_h"
  exit 1
fi

# width-right on the same window moves the split boundary and pins that screen edge.
read -r before_x _y before_w _h < <(read_box "$left")
"$UMBRIEL" msg window-modify-width-right:0.1 > /dev/null

wait_for_left_width_right() {
  local out= x y w h
  for _ in $(seq 60); do
    read -r x y w h < <(read_box "$left")
    if (( x == before_x && w > before_w )); then
      return 0
    fi
    sleep 0.1
  done
  echo "width-right did not pin the left screen edge: $x $y $w $h, expected x==$before_x w>$before_w"
  return 1
}
wait_for_left_width_right

# The right window's right edge faces the screen, and its left edge rides the split.
read -r before_x _y before_w _h < <(read_box "$right")
focus "$right"
"$UMBRIEL" msg window-modify-width-right:0.1 > /dev/null
sleep 0.5
read -r after_x after_y after_w after_h < <(read_box "$right")
if [[ "$after_x $after_y $after_w $after_h" != "$before_x $before_y $before_w $before_h" ]]; then
  echo "width-right resized a screen-facing edge: $before_x $before_y $before_w $before_h -> $after_x $after_y $after_w $after_h"
  exit 1
fi

read -r before_x _y before_w _h < <(read_box "$right")
"$UMBRIEL" msg window-modify-width-left:0.1 > /dev/null

wait_for_right_width_left() {
  local out= x y w h
  for _ in $(seq 60); do
    read -r x y w h < <(read_box "$right")
    if (( x < before_x && w > before_w && x + w == before_x + before_w )); then
      return 0
    fi
    sleep 0.1
  done
  echo "width-left did not pin the right screen edge: $x $y $w $h, expected x<$before_x w>$before_w x+w==$((before_x + before_w))"
  return 1
}
wait_for_right_width_left

echo "edge-anchored resize actions pin their opposite edge: height in a stacked column, width at dwindle's screen-facing edges"
