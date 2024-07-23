def simplify_alert($a):
  # Convert Elastic Security alert into a simpler flatter object
  {
      "created_at": $a."kibana.alert.start",
      "updated_at": $a."kibana.alert.workflow_status_updated_at",
      "severity": $a."kibana.alert.rule.parameters".severity,
      "status": $a."kibana.alert.workflow_status"
  };


def add_time_to_respond($a):
  # Update alert object with `.response_time_secs` calculated from `.created_at` and `.updated_at`
  $a
  | (. + {
    "created_at_timestamp": (.created_at | split(".")[0] | strptime("%Y-%m-%dT%H:%M:%S") | mktime),
    "updated_at_timestamp": (.updated_at | split(".")[0] | strptime("%Y-%m-%dT%H:%M:%S") | mktime)
  })
  # Calculate response time:
  | .response_time_secs = (.updated_at_timestamp - .created_at_timestamp);


def add_sla_match($alert; $hour_limits_per_severity):
  # Update alert object with `.in_sla` bool value if `.response_time_secs` is in corresponding SLA window per seveiry
  $alert
  | .sla_for_severity_secs = ($hour_limits_per_severity[.severity] * 60 * 60)
  | .in_sla = (.response_time_secs <= .sla_for_severity_secs);


def calculate_sla_metrics($hours_per_severity_slas; $alerts):
  # Elastic Alerts do not have history, so we can't see:
  # - when an alert was assigned
  # - when an alert was marked as "acknowledged", if it was marked as "closed" after
  # - when an alert was attached to a case
  # We calculate "response time" as time between alert creation and status change to "acknowledged" or "closed"

  ["critical", "high", "medium", "low"] as $severity_order  # rows order
  | [
      $alerts[]._source
        | simplify_alert(.)
        | select(.status == "acknowledged" or .status == "closed")
        | add_time_to_respond(.)
        | add_sla_match(.; $hours_per_severity_slas)
    ]
    | group_by(.severity)
    | map({
        (.[0].severity) : {
          "slas": (
            .
            | group_by(.in_sla)
            | map({( if .[0].in_sla then "in_sla" else "out_sla" end): length})
            | map( . |= {"in_sla": 0, "out_sla": 0} + .)  # set default values 
            | add
          ),
          "time_to_respond_hours": {
            "median": (
              map(.response_time_secs)
              | sort
              # Calculating a median value
              | (
                 if length == 0 then null
                 elif length % 2 == 0 then (.[length/2] + .[length/2-1])/2
                 else .[length/2 | floor]
                 end
               ) / (60 * 60)
            ),
            "max": (map(.response_time_secs) | max / (60 * 60))
          }
        }
      })
    | add as $metrics
    | $severity_order
    | map({
      "severity": .,
      "max_hours": $hours_per_severity_slas[.],
      "metrics": $metrics[.].slas,
      "time_to_respond_hours": $metrics[.].time_to_respond_hours
    });


def calculate_time_to_respond_metrics($alerts):
  # Calculate mean time to respond and 95th percentile value from the list of alerts
  [
    $alerts[]._source
    | simplify_alert(.)
    | select(.status == "acknowledged" or .status == "closed")
    | add_time_to_respond(.)
  ] as $alerts
  | {
      mean_time_to_respond_hours: ((($alerts[] | [.response_time_secs] | add/length) / (60  * 60)) // 0),
      percentile_95th_hours: (
        if (($alerts | length) > 0) then
          (
            $alerts
              | ((0.95 * length) | floor) as $index
              | sort_by(.response_time_secs)[$index]
              | .response_time_secs / (60 * 60)
          )
        else 0
        end
    )
  };


def parse_shift_boundary($week_start; $shift_boundary):
  # Parse a shift bounadry like "Mon, 08:00" into a timestamp
  ($shift_boundary + ", " + ($week_start | strftime("%W, %Y"))) | strptime("%a, %H:%M, %W, %Y") | mktime;


def shift_range_to_timestamp_range($week_start; $shift):
  # Parse a pair of shift boundary strings into a pair of timestamps
  [
    parse_shift_boundary($week_start; $shift[0]),
    parse_shift_boundary($week_start; $shift[1])
  ];


def hour_in_ranges($hour; $ranges):
  # Chech if a specific hour is in provided ranges
  any($ranges[]; .[0] <= $hour and $hour < .[1]);


def get_metrics_per_hour($alerts; $shifts; $hour):
  # Calculate analyst shift metrics per hour
  $shifts | to_entries
  | map(if select(.value | hour_in_ranges($hour; .)) then
      .key
    else
      empty
    end)
  | {
      "hour": $hour,
      "analysts": .,
      "alerts_count": ($alerts | map(select(.[0] == $hour)) | .[0][1] // 0)
    };


def get_metrics_per_analyst($metrics; $analyst_shifts):
  # Calculate shift metrics per analyst
  $analyst_shifts.key as $name
  | $analyst_shifts.value as $shifts
  | (
    $metrics
    | map(
        # Selecting only the hours when the analyst was on shift
        select(.analysts | contains([$name]))
        # Select only the hours with only one analyst
        | select((.analysts | length) == 1)
    )
    # Calculating average alert/h value over all hours the analyst was on shift
    | length
  ) as $hours_alone
  | (
    $metrics
    | map(
        # Selecting only the hours when the analyst was on shift
        select(.analysts | contains([$name]))
        # Dividing number of alerts in an hour by numbert of analysts on shift
        | (.alerts_count / (.analysts | length))
    )
    # Calculating average alert/h value over all hours the analyst was on shift
    | if length == 0 then 0 else (add // 0) / length end
  ) as $avg_alerts_per_hour
  | {
    "analyst": $name,
    "avg_alerts_per_hour": $avg_alerts_per_hour,
    "hours_alone": $hours_alone,
    "shifts": ($shifts | map([
      (.[0] | strftime("%Y-%m-%dT%H:%M")),
      (.[1] | strftime("%Y-%m-%dT%H:%M"))
    ]))
  };


def calculate_alerts_load_metrics($week_start; $week_end; $analyst_shifts; $alerts_per_hour):
  # Calculate global and analyst-specific shift metrics
  #
  # NOTE: the alert counts are for _created_ alerts. The overflow of alerts from unattended hours
  # is not taken into account, but might significantly contribute to the alert load.
  (
      $analyst_shifts
      | to_entries
      # Per analyst, convert the list of shift boundary pairs into a list of timestamp pairs
      | map({(.key): .value | map(shift_range_to_timestamp_range($week_start; .))})
      | add
    ) as $shifts_map
  | (
      $alerts_per_hour
      | map(
          [
            # 2024-05-13T14:00:00.000Z
            (.[0] | strptime("%Y-%m-%dT%H:00:00.000Z") | mktime),
            .[1]
          ]
        )
    ) as $alerts
  | $week_start as $walker
  | [$walker]
  # Break down the week into a list of hours
  | map(while(. < $week_end; . + 60 * 60))
  # Calculate hourly metrics
  | map(get_metrics_per_hour($alerts; $shifts_map; .)) as $metrics
  | {
      "analyst_metrics": [($shifts_map | to_entries[] | get_metrics_per_analyst($metrics; .))],
      "unattended_hours": [$metrics[] | select(.analysts == [])] | length,
      "alerts_during_unattended_hours": (([$metrics[] | select(.analysts == []) | .alerts_count] | add) // 0),
      "dead_hours": [$metrics[] | select(.alerts_count == 0)] | length,
      "shifts": ($shifts_map | map([.[0] | tostring, .[1] | tostring])),
      "week_start": ($week_start | strftime("%Y-%m-%d %H:%M")),
      "week_end": ($week_end | strftime("%Y-%m-%d %H:%M"))
    };


def gather_data_for_summarisation(
  $alerts_with_impact;
  $slas;
  $alerts_curr;
  $alerts_wo_impact_per_tag;
  $rules;
  $rules_enabled_per_rule_id;
  $rules_disabled_per_rule_id;
  $alerts_with_fp_per_rule_per_severity;
  $alerts_curr_per_severity;
  $alerts_prev_per_severity;
  $analyst_shifts
):
  # Prepare JSON object to be used in an LLM prompt.
  # Keep the field names are as descriptive as possible.
  {
    "alerts-with-materialized-risk": (
      $alerts_with_impact
      | map(._source)
      | map({
          "description": ."kibana.alert.rule.description",
          "name": ."kibana.alert.rule.name",
          "severity": ."kibana.alert.rule.parameters".severity,
      })
    ),
    "alert-service-level-agreement-metrics": calculate_sla_metrics( $slas; $alerts_curr),
    "false-positives-and-true-positives": (
      $alerts_wo_impact_per_tag as $agg_buckets
      | {
         "true_positives_count": ([($agg_buckets[] | select(.key == "True Positive"))][0].doc_count // 0),
         "false_positives_count": ([($agg_buckets[] | select(.key == "False Positive"))][0].doc_count // 0),
        }
      | .percentage = (
        if (.true_positives_count + .false_positives_count) > 0 then 
          ((.true_positives_count / (.true_positives_count + .false_positives_count) * 100) | floor)
        else
          0
        end)
    ),
    "rules-disabled-and-rules-enabled-in-current-period": (
      ($rules | map({(.id): .name}) | add) as $rules_map
      | {
        "enabled_rules_in_current_period": (($rules_enabled_per_rule_id // []) | map($rules_map[.key])),
        "disabled_rules_in_current_period": (($rules_disabled_per_rule_id // []) | map($rules_map[.key])),
        "overall_enabled_rules": ($rules | map(select(.enabled == true)) | length),
      }
    ),
    "rules-with-false-positives-per-severity-of-the-rule": $alerts_with_fp_per_rule_per_severity,
    "alerts-in-current-period-per-severity": $alerts_curr_per_severity,
    "alerts-in-previous-period-per-severity": $alerts_prev_per_severity,
    "analysts-on-shifts-in-current-period": ($analyst_shifts | length)
  };
