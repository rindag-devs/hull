/*
  This file is part of Hull.

  Hull is free software: you can redistribute it and/or modify it under the terms of the GNU
  Lesser General Public License as published by the Free Software Foundation, either version 3 of
  the License, or (at your option) any later version.

  Hull is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
  the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Lesser
  General Public License for more details.

  You should have received a copy of the GNU Lesser General Public License along with Hull. If
  not, see <https://www.gnu.org/licenses/>.
*/

{ lib, pkgs }:

{
  # Problem target name merged into the final Lemon custom contest package.
  problemTarget ? "lemonCustom",
}:
{
  _type = "hullContestTarget";
  __functor =
    self:
    {
      name,
      problems,
      ...
    }:
    let
      problemOutputs = map (p: p.config.targetOutputs.${problemTarget}) problems;
      problemCdfPaths = map (
        p: "${p.config.targetOutputs.${problemTarget}}/${p.config.name}.cdf"
      ) problems;
      numTasks = builtins.length problems;
    in
    pkgs.runCommandLocal "hull-contestTargetOutput-${name}-lemonCustom" { } ''
      tmpdir=$(mktemp -d)
      tmp_cdf=$(mktemp)
      cleanup() {
        rm -rf "$tmpdir"
        rm -f "$tmp_cdf"
      }
      trap cleanup EXIT

      mkdir -p "$tmpdir/data" "$tmpdir/source"

      for problemOutput in ${lib.concatStringsSep " " problemOutputs}; do
        for dataEntry in "$problemOutput"/data/*; do
          entryName=$(basename "$dataEntry")
          if [ "$entryName" = "_hull" ]; then
            continue
          fi
          cp -r "$dataEntry" "$tmpdir/data/"
          chmod -R u+w "$tmpdir/data/$entryName" 2>/dev/null || true
        done

        for contestantDir in "$problemOutput"/source/*; do
          if [ -d "$contestantDir" ]; then
            contestantName=$(basename "$contestantDir")
            mkdir -p "$tmpdir/source/$contestantName"
            cp -r "$contestantDir"/* "$tmpdir/source/$contestantName/"
            chmod -R u+w "$tmpdir/source/$contestantName" 2>/dev/null || true
          fi
        done
      done

      mkdir -p "$tmpdir/data/_hull/nix/store"
      first_problem_output=""
      for problemOutput in ${lib.concatStringsSep " " problemOutputs}; do
        if [ -z "$first_problem_output" ]; then
          first_problem_output="$problemOutput"
        fi
        if [ -d "$problemOutput/data/_hull/nix/store" ]; then
          for storeEntry in "$problemOutput"/data/_hull/nix/store/*; do
            entryName=$(basename "$storeEntry")
            if [ ! -e "$tmpdir/data/_hull/nix/store/$entryName" ]; then
              cp -a --no-preserve=ownership "$storeEntry" "$tmpdir/data/_hull/nix/store/"
              chmod -R u+w "$tmpdir/data/_hull/nix/store/$entryName" 2>/dev/null || true
            fi
          done
        fi
      done
      if [ -n "$first_problem_output" ] && [ -d "$first_problem_output/data/_hull" ]; then
        for hullEntry in "$first_problem_output"/data/_hull/*; do
          entryName=$(basename "$hullEntry")
          if [ "$entryName" = "nix" ]; then
            continue
          fi
          cp -a --no-preserve=ownership "$hullEntry" "$tmpdir/data/_hull/"
        done
        chmod -R u+w "$tmpdir/data/_hull" 2>/dev/null || true
      fi

      ${lib.getExe pkgs.jq} -cn \
        --arg version "1.0" \
        --arg title "${name}" \
        '{version: $version, contestTitle: $title, tasks: [], contestants: []}' \
        > "$tmpdir/${name}.cdf"

      for cdf_path in ${lib.concatStringsSep " " problemCdfPaths}; do
        ${lib.getExe pkgs.jq} -c --slurpfile prob_cdf "$cdf_path" \
          '.tasks += $prob_cdf[0].tasks' \
          "$tmpdir/${name}.cdf" > "$tmp_cdf"
        mv "$tmp_cdf" "$tmpdir/${name}.cdf"
      done

      contestantNames=$(ls "$tmpdir/source" 2>/dev/null || true)
      for contestantName in $contestantNames; do
        checkJudgedStr=$(printf 'false,%.0s' $(seq ${toString numTasks}) | sed 's/,$//')
        compileStateStr=$(printf '1,%.0s' $(seq ${toString numTasks}) | sed 's/,$//')
        emptyStr=$(printf '"",%.0s' $(seq ${toString numTasks}) | sed 's/,$//')
        emptyArr=$(printf '[],%.0s' $(seq ${toString numTasks}) | sed 's/,$//')

        ${lib.getExe pkgs.jq} -c \
          --arg name "$contestantName" \
          --argjson check_judged_str "[$checkJudgedStr]" \
          --argjson compile_state_str "[$compileStateStr]" \
          --argjson empty_str "[$emptyStr]" \
          --argjson empty_arr "[$emptyArr]" \
          '.contestants += [{
            contestantName: $name,
            checkJudged: $check_judged_str,
            compileState: $compile_state_str,
            sourceFile: $empty_str,
            compileMesaage: $empty_str,
            inputFiles: $empty_arr,
            result: $empty_arr,
            message: $empty_arr,
            score: $empty_arr,
            timeUsed: $empty_arr,
            memoryUsed: $empty_arr,
            judgingTime_date: 0,
            judgingTime_time: 0,
            judgingTime_timespec: 0
          }]' \
          "$tmpdir/${name}.cdf" > "$tmp_cdf"
        mv "$tmp_cdf" "$tmpdir/${name}.cdf"
      done

      mkdir -p $out
      cp -r "$tmpdir"/. $out/
    '';
}
