// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"fmt"
	"strconv"
	"strings"

	"github.com/spf13/cobra"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

type watchOptions struct {
	decoder   string
	freqHz    uint64
	device    string
	deviceID  string
	takeOver  bool
	detach    bool
	count     int
	predicate *leylinev1.Predicate
	notify    *leylinev1.NotifyTarget
	predWords string
}

func newWatchCommand(app *App) *cobra.Command {
	var (
		o        watchOptions
		freq     string
		where    []string
		counties []string
		near     string
		radius   string
		notify   string
		asJob    bool
	)
	cmd := &cobra.Command{
		Use:   "watch <decoder>",
		Short: "Decode with a filter, and fire a notifier when it matches",
		Long: `watch runs a decoder like 'ley decode', but only shows records that pass a
filter, and can hand a match to a notifier. It is how you wait for one thing
on the air: a county's weather alert, a particular station, traffic from a
place.

By default watch stays attached and streams the matching records, the way
decode streams every record. --detach leaves the job running in the daemon
after ley exits, so the notifier fires with nothing connected -- which is the
point of a watch: an alert must reach you when you are not looking. --detach
prints the job id and how to stop it ('ley jobs cancel') and exits.

The filter is built from the flags, ANDed together:

  --where field=value   an equality test; also field!=value (not equal),
                        field~value (contains), and field>value, >=, <, <=
                        (numeric). Repeat for more tests.
  --county FIPS         a county's records: a CONTAINS test on the 'fips'
                        field a SAME alert carries. Repeat for more counties;
                        a record matches if it names any of them.
  --near LAT,LON --radius R   records from a place (R is 10km, 500m, 5nm, 3mi).

--notify hands each match to a notifier. Bare --notify is a macOS
notification; --notify=webhook:URL POSTs the record, --notify=shell:CMD runs
a command with the record's JSON on stdin (an explicit target takes the '='
form, so a bare --notify can still mean the macOS one). The daemon runs the
notifier, so it fires whether or not ley is attached.

--json prints one DecodeRecord per line (NDJSON): the matches and nothing else.`,
		Example: `  ley watch same --county 06009 --notify        # a weather alert for your county
  ley watch aprs --where device_id=LEYTST-1     # one station
  ley watch aprs --where 'temp_c>25'            # only when it is warm
  ley watch aprs --near 37.76,-122.42 --radius 10km
  ley watch same --county 06009 --notify=shell:'say alert' --detach`,
		GroupID: GroupLooking,
		Args:    cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			o.decoder = args[0]
			if freq != "" {
				hz, err := leyline.ParseUserFrequency(freq)
				if err != nil {
					return usageErrorf("--freq: %v", err)
				}
				o.freqHz = hz
			}
			pred, words, err := buildPredicate(where, counties, near, radius)
			if err != nil {
				return err
			}
			o.predicate, o.predWords = pred, words
			if cmd.Flags().Changed("notify") {
				if o.notify, err = parseNotify(notify); err != nil {
					return err
				}
			}
			o.detach = asJob
			s, err := openSession(cmd.Context(), app)
			if err != nil {
				return err
			}
			defer s.close()
			if o.device != "" {
				d, derr := pickDevice(s.state, o.device)
				if derr != nil {
					return derr
				}
				o.deviceID = d.DeviceId
			}
			s.proseToStderr = true
			return runWatch(cmd.Context(), s, o)
		},
	}
	cmd.Flags().StringVar(&freq, "freq", "", "watch somewhere other than the recipe's frequency, e.g. 144.8 (a bare number is MHz)")
	cmd.Flags().StringVar(&o.device, "device", "", "which radio: an id (dev_...), id prefix or row number from 'ley devices' (default: the first real radio)")
	cmd.Flags().BoolVar(&o.takeOver, "take-over", false, "watch even when somebody is using the radio; it is theirs again afterwards")
	cmd.Flags().StringArrayVar(&where, "where", nil, "a field test: field=value, field!=value, field~value, field>value (repeatable)")
	cmd.Flags().StringArrayVar(&counties, "county", nil, "a FIPS county code the record must name in its 'fips' field, e.g. 06009 (repeatable)")
	cmd.Flags().StringVar(&near, "near", "", "records from around here: LAT,LON, e.g. 37.76,-122.42 (needs --radius)")
	cmd.Flags().StringVar(&radius, "radius", "", "how far around --near to look: 10km, 500m, 5nm, 3mi")
	cmd.Flags().StringVar(&notify, "notify", "", "hand each match to a notifier: bare (macOS notification), webhook:URL or shell:CMD")
	cmd.Flags().Lookup("notify").NoOptDefVal = "macos"
	cmd.Flags().BoolVar(&asJob, "detach", false, "leave the job running after ley exits so the notifier fires unattended ('ley jobs cancel' stops it)")
	cmd.Flags().BoolVar(&asJob, "job", false, "alias for --detach")
	cmd.Flags().IntVar(&o.count, "count", 0, "stop after this many matches, e.g. 5 (default: until Ctrl-C)")
	return cmd
}

// runWatch starts the decode job with its predicate and notifier. Attached (the default) it
// streams the matching records the way decode streams every record; detached it leaves the job
// running for the notifier and prints how to stop it.
func runWatch(ctx context.Context, s *session, o watchOptions) error {
	cfg := &leylinev1.DecodeConfig{
		Decoder:     o.decoder,
		FrequencyHz: o.freqHz,
		DeviceId:    o.deviceID,
		TakeOver:    o.takeOver,
		Keep:        o.detach,
		Predicate:   o.predicate,
		Notify:      o.notify,
	}
	job, err := s.client.StartDecode(ctx, cfg)
	if err != nil {
		return decodeFailure(s, decodeOptions{decoder: o.decoder}, err)
	}
	s.say("%s\n", watchBanner(s, job, o))
	if o.detach {
		st := s.app.ErrStyle
		s.say("left running; %s stops it\n", st.Cmd("ley jobs cancel "+jobRowName(s, job)))
		return nil
	}
	from := uint64(0)
	sctx, stop := context.WithCancel(ctx)
	defer stop()
	recs, errs, err := s.client.SubscribeRecords(sctx, leyline.RecordScopeJob(job.GetJobId(), &from))
	if err != nil {
		return err
	}
	n := 0
	for {
		select {
		case <-ctx.Done():
			return watchStopped(s, job)
		case err := <-errs:
			if err != nil && ctx.Err() == nil {
				return err
			}
			return watchStopped(s, job)
		case rec, ok := <-recs:
			if !ok {
				return watchStopped(s, job)
			}
			if err := printRecord(s, rec); err != nil {
				return err
			}
			n++
			if o.count > 0 && n >= o.count {
				return watchStopped(s, job)
			}
		}
	}
}

// watchStopped ends an attached watch: the job is ephemeral, so cancel it and hand the radio
// back, the way decode does with a job it started for one run.
func watchStopped(s *session, job *leylinev1.Job) error {
	st := s.app.ErrStyle
	ctx, cancel := context.WithTimeout(context.Background(), confirmTimeout)
	defer cancel()
	if _, err := s.client.Jobs.CancelJob(ctx, &leylinev1.JobRef{JobId: job.GetJobId()}); err != nil {
		s.say("the job is still running: %s stops it\n", st.Cmd("ley jobs cancel "+jobRowName(s, job)))
	}
	return nil
}

// watchBanner names what the watch is doing: the decoder and where it listens (from decode's
// banner), then the filter in words and the notifier, so a reader sees what will and will not
// reach them.
func watchBanner(s *session, job *leylinev1.Job, o watchOptions) string {
	st := s.app.ErrStyle
	where := ""
	if hz := decodeFrequency(s, job); hz > 0 {
		where = " on " + leyline.FormatFrequency(hz)
	}
	line := fmt.Sprintf("watching %s%s", o.decoder, where)
	if ch := decodeChannel(s); ch != nil {
		line += ", " + st.Muted(ch.GetChannelId())
	}
	line += "\n  " + st.Muted("filter: "+o.predWords)
	if o.notify != nil {
		line += "\n  " + st.Muted("notify: "+notifierWords(o.notify))
	}
	if o.detach {
		return line + "\n" + st.Muted("kept: it runs on after ley exits")
	}
	return line + "\nCtrl-C stops"
}

// buildPredicate turns the filter flags into a Predicate whose clauses are ANDed, and a plain
// sentence describing it for the banner. No clauses is a nil predicate, which the daemon matches
// against everything -- the same as `ley decode`.
func buildPredicate(where, counties []string, near, radius string) (*leylinev1.Predicate, string, error) {
	var clauses []*leylinev1.Clause
	var words []string
	for _, tok := range where {
		c, w, err := parseWhere(tok)
		if err != nil {
			return nil, "", err
		}
		clauses = append(clauses, c)
		words = append(words, w)
	}
	if len(counties) > 0 {
		var vals []*leylinev1.FieldValue
		for _, code := range counties {
			vals = append(vals, textValue(strings.TrimSpace(code)))
		}
		clauses = append(clauses, &leylinev1.Clause{Test: &leylinev1.Clause_Field{Field: &leylinev1.FieldTest{
			Field: "fips", Op: leylinev1.PredicateOp_PRED_CONTAINS, Values: vals,
		}}})
		words = append(words, "fips names one of "+strings.Join(counties, ", "))
	}
	switch {
	case near != "" && radius == "":
		return nil, "", usageErrorf("--near needs --radius: a point without a distance says nothing about which records to keep (try --radius 10km)")
	case near == "" && radius != "":
		return nil, "", usageErrorf("--radius needs --near: a distance without a point has nothing to measure from (try --near 37.76,-122.42)")
	case near != "":
		pos, err := parseLatLon(near)
		if err != nil {
			return nil, "", usageErrorf("--near: %v", err)
		}
		r, err := parseDistance(radius)
		if err != nil {
			return nil, "", usageErrorf("--radius: %v", err)
		}
		clauses = append(clauses, &leylinev1.Clause{Test: &leylinev1.Clause_Geo{Geo: &leylinev1.GeoTest{Center: pos, RadiusM: r}}})
		words = append(words, fmt.Sprintf("within %s of %s", radius, near))
	}
	if len(clauses) == 0 {
		return nil, "everything (no filter)", nil
	}
	return &leylinev1.Predicate{All: clauses}, strings.Join(words, "; "), nil
}

// whereOp maps a token's operator to the predicate op and the word for it, longest operators
// first so "!=" is not read as "=".
var whereOps = []struct {
	tok  string
	op   leylinev1.PredicateOp
	word string
	num  bool
}{
	{"!=", leylinev1.PredicateOp_PRED_NE, "!=", false},
	{">=", leylinev1.PredicateOp_PRED_GTE, ">=", true},
	{"<=", leylinev1.PredicateOp_PRED_LTE, "<=", true},
	{"~", leylinev1.PredicateOp_PRED_CONTAINS, "contains", false},
	{">", leylinev1.PredicateOp_PRED_GT, ">", true},
	{"<", leylinev1.PredicateOp_PRED_LT, "<", true},
	{"=", leylinev1.PredicateOp_PRED_EQ, "=", false},
}

// parseWhere reads one --where token: a field name, an operator, and a value. The operator is
// parsed out of the token (field=value, field!=value, field~value, field>value, ...). A numeric
// operator carries its value as a number; the rest carry text.
func parseWhere(tok string) (*leylinev1.Clause, string, error) {
	for i := 0; i < len(tok); i++ {
		for _, o := range whereOps {
			if !strings.HasPrefix(tok[i:], o.tok) {
				continue
			}
			field, value := tok[:i], tok[i+len(o.tok):]
			if field == "" {
				return nil, "", usageErrorf("--where %q has no field before %q; write it field%svalue", tok, o.tok, o.tok)
			}
			if value == "" {
				return nil, "", usageErrorf("--where %q has no value after %q; write it %s%svalue", tok, o.tok, field, o.tok)
			}
			ft := &leylinev1.FieldTest{Field: field, Op: o.op}
			if o.num {
				n, err := strconv.ParseFloat(value, 64)
				if err != nil {
					return nil, "", usageErrorf("--where %q: %q needs a number for %s", tok, value, o.word)
				}
				ft.Values = []*leylinev1.FieldValue{numberValue(n)}
			} else {
				ft.Values = []*leylinev1.FieldValue{textValue(value)}
			}
			return &leylinev1.Clause{Test: &leylinev1.Clause_Field{Field: ft}}, field + " " + o.word + " " + value, nil
		}
	}
	return nil, "", usageErrorf("--where %q has no operator; write it field=value (or !=, ~, >, >=, <, <=)", tok)
}

// parseNotify reads the --notify value: bare (or "macos") is a macOS notification, webhook:URL a
// webhook, shell:CMD a shell hook. The scheme is the part before the first colon.
func parseNotify(v string) (*leylinev1.NotifyTarget, error) {
	if v == "macos" {
		return &leylinev1.NotifyTarget{Target: &leylinev1.NotifyTarget_MacosNotification{MacosNotification: true}}, nil
	}
	scheme, rest, ok := strings.Cut(v, ":")
	if !ok {
		return nil, usageErrorf("--notify %q is not a target; use --notify alone (a macOS notification), or webhook:URL or shell:CMD", v)
	}
	switch scheme {
	case "webhook":
		if rest == "" {
			return nil, usageErrorf("--notify webhook: needs a URL, e.g. webhook:https://example.com/hook")
		}
		return &leylinev1.NotifyTarget{Target: &leylinev1.NotifyTarget_Webhook{Webhook: rest}}, nil
	case "shell":
		if rest == "" {
			return nil, usageErrorf("--notify shell: needs a command, e.g. shell:'say alert'")
		}
		return &leylinev1.NotifyTarget{Target: &leylinev1.NotifyTarget_Shell{Shell: rest}}, nil
	case "macos":
		return &leylinev1.NotifyTarget{Target: &leylinev1.NotifyTarget_MacosNotification{MacosNotification: true}}, nil
	default:
		return nil, usageErrorf("--notify %q has an unknown target %q; use webhook:URL, shell:CMD or bare --notify", v, scheme)
	}
}

// notifierWords describes a notifier for the banner.
func notifierWords(t *leylinev1.NotifyTarget) string {
	switch tt := t.GetTarget().(type) {
	case *leylinev1.NotifyTarget_Webhook:
		return "webhook to " + tt.Webhook
	case *leylinev1.NotifyTarget_Shell:
		return "shell: " + tt.Shell
	case *leylinev1.NotifyTarget_MacosNotification:
		return "macOS notification"
	default:
		return "none"
	}
}

func textValue(s string) *leylinev1.FieldValue {
	return &leylinev1.FieldValue{Value: &leylinev1.FieldValue_Text{Text: s}}
}

func numberValue(v float64) *leylinev1.FieldValue {
	return &leylinev1.FieldValue{Value: &leylinev1.FieldValue_Number{Number: v}}
}
