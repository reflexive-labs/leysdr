// SPDX-License-Identifier: Apache-2.0

package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/textproto"
	"net/url"
	"strings"
	"time"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
)

// The openai engine calls an OpenAI-compatible transcription endpoint, POST
// {base}/v1/audio/transcriptions, with net/http rather than a client library: one multipart
// request and a handful of outcomes are this file, and a library would bring licence rows for
// them. The base is OpenAI's own API, or the endpoint the key was added with, which is how a
// compatible server (a gateway, a local whisper server) is reached.

// openaiAPI is OpenAI's own base, used when the key names no endpoint.
const openaiAPI = "https://api.openai.com"

// openaiDefaultModel is the model asked for when the speech feature names none.
const openaiDefaultModel = "whisper-1"

// openaiTimeout bounds one call. A four-minute over takes tens of seconds to upload and
// transcribe; a call that takes longer is a provider that is not answering.
const openaiTimeout = 60 * time.Second

// openaiMaxUpload is the largest file OpenAI takes in one call, 25 MB. A 16-bit mono WAV at
// 48 kHz reaches it at about 4.5 minutes.
const openaiMaxUpload = 25 << 20

// openaiMaxBody bounds the response read. A verbose transcript of ten minutes is tens of KB.
const openaiMaxBody = 4 << 20

// openAI is the engine. key is the user's, read from stdin, and goes in the Authorization header
// of a request to url and nowhere else.
type openAI struct {
	url string
	key string
	// keyName is the provider the key was added under, which `ley ai check` takes.
	keyName  string
	host     string // the usage report's provider: "openai", or the endpoint's host
	modelID  string
	language string
	prompt   string
	// format is the response_format asked for: verbose_json, which carries the language and the
	// per-segment figures confidence comes from, until a model says it does not support it.
	format string
	http   *http.Client
}

func newOpenAI(cfg engineConfig, cred *leylinev1.SetCredentialRequest) (engine, error) {
	if cred.GetSecret() == "" {
		return nil, errors.New("the openai engine needs the key the daemon hands over on stdin; " +
			"the installed manifest names no credential_provider, so none was sent")
	}
	base, host, err := openaiBase(cred.GetEndpoint())
	if err != nil {
		return nil, err
	}
	o := &openAI{
		url:      base + "/v1/audio/transcriptions",
		key:      cred.GetSecret(),
		keyName:  cred.GetProvider(),
		host:     host,
		modelID:  cfg.model,
		language: cfg.language,
		prompt:   cfg.prompt,
		format:   "verbose_json",
		// Never follow a redirect: Go re-sends a header set by hand to the redirect's host, and
		// the key must reach no host but the one the user added it for.
		http: &http.Client{
			Timeout:       openaiTimeout,
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		},
	}
	if o.modelID == "" {
		o.modelID = openaiDefaultModel
	}
	return o, nil
}

// openaiBase is the API base with no trailing slash or /v1, and the name the usage report gives
// the provider. An endpoint must be https, or plain http to this machine only, so the key never
// crosses the network in the clear.
func openaiBase(endpoint string) (base, host string, err error) {
	if endpoint == "" {
		return openaiAPI, "openai", nil
	}
	u, err := url.Parse(endpoint)
	if err != nil || u.Host == "" {
		return "", "", fmt.Errorf("the endpoint %q is not a URL", endpoint)
	}
	local := u.Hostname() == "localhost" || u.Hostname() == "127.0.0.1" || u.Hostname() == "::1"
	if u.Scheme != "https" && (u.Scheme != "http" || !local) {
		return "", "", fmt.Errorf("the endpoint must be https: %s would send the key in the clear", u.Redacted())
	}
	// An OpenAI-compatible base URL is often written with its /v1 already on it.
	base = strings.TrimSuffix(strings.TrimRight(endpoint, "/"), "/v1")
	return base, u.Hostname(), nil
}

func (o *openAI) provider() string { return o.host }
func (o *openAI) model() string    { return o.modelID }

// verboseTranscript is the part of a verbose_json response the record is built from. A plain
// json response has only text.
type verboseTranscript struct {
	Text     string `json:"text"`
	Language string `json:"language"`
	Segments []struct {
		NoSpeechProb *float64 `json:"no_speech_prob"`
	} `json:"segments"`
}

func (o *openAI) transcribe(samples []float32, audioRate float64, _ int) (transcript, error) {
	wav := encodeWAV(samples, uint32(audioRate))
	if len(wav) > openaiMaxUpload {
		return transcript{}, fmt.Errorf("%.0f s of audio is %d MB as WAV, over the %d MB a call takes; not sent",
			float64(len(samples))/audioRate, len(wav)>>20, openaiMaxUpload>>20)
	}
	body, err := o.call(wav)
	var refused *formatRefused
	if errors.As(err, &refused) && o.format != "json" {
		// Newer models answer only plain json, which has no language or segments; ask again in
		// it, and keep asking in it for the rest of the run.
		o.format = "json"
		body, err = o.call(wav)
	}
	if err != nil {
		return transcript{}, err
	}
	var resp verboseTranscript
	if err := json.Unmarshal(body, &resp); err != nil {
		return transcript{}, fmt.Errorf("the response is not a transcription's JSON: %w", err)
	}
	tr := transcript{text: strings.TrimSpace(resp.Text), language: o.language, raw: body}
	if resp.Language != "" {
		tr.language = languageCode(resp.Language)
	}
	tr.confidence, tr.hasConfidence = speechConfidence(resp)
	return tr, nil
}

// speechConfidence is 1 less the mean of the segments' no_speech_prob, the model's own estimate
// that a stretch held no speech. With no segment reporting one there is no figure, and the record
// says nothing rather than inventing one.
func speechConfidence(resp verboseTranscript) (float64, bool) {
	sum, n := 0.0, 0
	for _, s := range resp.Segments {
		if s.NoSpeechProb != nil {
			sum += *s.NoSpeechProb
			n++
		}
	}
	if n == 0 {
		return 0, false
	}
	return max(0, min(1, 1-sum/float64(n))), true
}

// formatRefused is a 400 naming response_format: the model does not offer verbose_json.
type formatRefused struct{ msg string }

func (e *formatRefused) Error() string { return e.msg }

// call makes one request and returns the body of a 200. Every other outcome is an error: a
// *stopError when the plugin must exit (see refusal), a plain error when only this segment is
// lost.
func (o *openAI) call(wav []byte) ([]byte, error) {
	form, contentType, err := o.form(wav)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequest(http.MethodPost, o.url, bytes.NewReader(form))
	if err != nil {
		return nil, &stopError{exit: 1, msg: fmt.Sprintf("the endpoint %s is not a URL", o.host)}
	}
	req.Header.Set("Content-Type", contentType)
	req.Header.Set("Authorization", "Bearer "+o.key)
	resp, err := o.http.Do(req)
	if err != nil {
		// Offline, a name that does not resolve, a timeout: the provider may answer later.
		return nil, &stopError{exit: exitTempFail, msg: o.scrub(fmt.Sprintf("%s did not answer: %v", o.host, err))}
	}
	defer func() { _ = resp.Body.Close() }()
	body, err := io.ReadAll(io.LimitReader(resp.Body, openaiMaxBody))
	if err != nil {
		return nil, &stopError{exit: exitTempFail, msg: o.scrub(fmt.Sprintf("%s: reading the response: %v", o.host, err))}
	}
	if resp.StatusCode == http.StatusOK {
		return body, nil
	}
	return nil, o.refusal(resp, body)
}

// form is the multipart body: the audio, the model, the response format, and the language and
// vocabulary hint when there are any.
func (o *openAI) form(wav []byte) ([]byte, string, error) {
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	h := textproto.MIMEHeader{}
	h.Set("Content-Disposition", `form-data; name="file"; filename="over.wav"`)
	h.Set("Content-Type", "audio/wav")
	part, err := mw.CreatePart(h)
	if err != nil {
		return nil, "", err
	}
	if _, err := part.Write(wav); err != nil {
		return nil, "", err
	}
	fields := [][2]string{{"model", o.modelID}, {"response_format", o.format}}
	if o.language != "" {
		fields = append(fields, [2]string{"language", o.language})
	}
	if o.prompt != "" {
		fields = append(fields, [2]string{"prompt", o.prompt})
	}
	for _, f := range fields {
		if err := mw.WriteField(f[0], f[1]); err != nil {
			return nil, "", err
		}
	}
	if err := mw.Close(); err != nil {
		return nil, "", err
	}
	return buf.Bytes(), mw.FormDataContentType(), nil
}

// refusal maps a status other than 200 onto what the plugin does next:
//
//   - 401 or 403, a rejected key: exit 1. Trying again on the restart backoff cannot help, and the
//     person checks the key with `ley ai check`.
//   - 429, 5xx, or a 400 about credit or billing: the provider's own limit or outage, exit 75
//     with its words, which the daemon waits out on a kept job and reports as PROVIDER_REFUSED
//     on any other.
//   - a redirect or a 404: the endpoint is not a transcription API; exit 1.
//   - any other 4xx: this segment's audio was refused (too short, say); the segment is lost and
//     the next is tried.
func (o *openAI) refusal(resp *http.Response, body []byte) error {
	said := o.scrub(providerMessage(resp, body))
	status := resp.StatusCode
	switch {
	case status == http.StatusUnauthorized || status == http.StatusForbidden:
		return &stopError{exit: 1, msg: fmt.Sprintf("%s rejected the key (%s: %s); check it with ley ai check %s",
			o.host, resp.Status, said, o.keyName)}
	case status == http.StatusTooManyRequests || status >= 500 || (status == http.StatusBadRequest && mentionsBilling(said)):
		return &stopError{exit: exitTempFail, msg: fmt.Sprintf("%s: %s: %s", o.host, resp.Status, said)}
	case status >= 300 && status < 400:
		to := "another address"
		if loc, err := resp.Location(); err == nil {
			to = loc.Host
		}
		return &stopError{exit: 1, msg: fmt.Sprintf("%s redirected the call to %s, and the key is not sent on", o.host, to)}
	case status == http.StatusNotFound:
		return &stopError{exit: 1, msg: fmt.Sprintf("%s has no transcription API at %s (%s: %s)", o.host, o.url, resp.Status, said)}
	case status == http.StatusBadRequest && strings.Contains(said, "response_format"):
		return &formatRefused{msg: said}
	}
	return fmt.Errorf("%s refused the audio: %s: %s", o.host, resp.Status, said)
}

// scrub cuts the key out of a message: a gateway may echo the request back, header and all, and
// the message goes to stderr, which the daemon logs.
func (o *openAI) scrub(msg string) string {
	if o.key == "" {
		return msg
	}
	return strings.ReplaceAll(msg, o.key, "…")
}

// providerMessage is the provider's own words: the message in its error body (OpenAI sends
// {"error": {"message": ...}}), else the body as text, else the status line, on one line of at
// most 300 characters.
func providerMessage(resp *http.Response, body []byte) string {
	var shaped struct {
		Error struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	msg := string(body)
	if json.Unmarshal(body, &shaped) == nil && shaped.Error.Message != "" {
		msg = shaped.Error.Message
	}
	msg = strings.Join(strings.Fields(msg), " ")
	if msg == "" {
		msg = resp.Status
	}
	if r := []rune(msg); len(r) > 300 {
		msg = string(r[:299]) + "…"
	}
	return msg
}

func mentionsBilling(msg string) bool {
	msg = strings.ToLower(msg)
	return strings.Contains(msg, "credit") || strings.Contains(msg, "billing")
}

// languageCode turns the language a verbose_json response names ("english") into its ISO 639-1
// code. A name not in Whisper's list is kept as the provider wrote it, in lower case.
func languageCode(name string) string {
	name = strings.ToLower(strings.TrimSpace(name))
	if code, ok := whisperLanguages[name]; ok {
		return code
	}
	return name
}

// whisperLanguages is Whisper's language list, by the name its responses use. Cantonese and
// Hawaiian have no two-letter code and keep Whisper's.
var whisperLanguages = map[string]string{
	"afrikaans": "af", "albanian": "sq", "amharic": "am", "arabic": "ar", "armenian": "hy",
	"assamese": "as", "azerbaijani": "az", "bashkir": "ba", "basque": "eu", "belarusian": "be",
	"bengali": "bn", "bosnian": "bs", "breton": "br", "bulgarian": "bg", "cantonese": "yue",
	"catalan": "ca", "chinese": "zh", "croatian": "hr", "czech": "cs", "danish": "da",
	"dutch": "nl", "english": "en", "estonian": "et", "faroese": "fo", "finnish": "fi",
	"french": "fr", "galician": "gl", "georgian": "ka", "german": "de", "greek": "el",
	"gujarati": "gu", "haitian creole": "ht", "hausa": "ha", "hawaiian": "haw", "hebrew": "he",
	"hindi": "hi", "hungarian": "hu", "icelandic": "is", "indonesian": "id", "italian": "it",
	"japanese": "ja", "javanese": "jv", "kannada": "kn", "kazakh": "kk", "khmer": "km",
	"korean": "ko", "lao": "lo", "latin": "la", "latvian": "lv", "lingala": "ln",
	"lithuanian": "lt", "luxembourgish": "lb", "macedonian": "mk", "malagasy": "mg", "malay": "ms",
	"malayalam": "ml", "maltese": "mt", "maori": "mi", "marathi": "mr", "mongolian": "mn",
	"myanmar": "my", "nepali": "ne", "norwegian": "no", "nynorsk": "nn", "occitan": "oc",
	"pashto": "ps", "persian": "fa", "polish": "pl", "portuguese": "pt", "punjabi": "pa",
	"romanian": "ro", "russian": "ru", "sanskrit": "sa", "serbian": "sr", "shona": "sn",
	"sindhi": "sd", "sinhala": "si", "slovak": "sk", "slovenian": "sl", "somali": "so",
	"spanish": "es", "sundanese": "su", "swahili": "sw", "swedish": "sv", "tagalog": "tl",
	"tajik": "tg", "tamil": "ta", "tatar": "tt", "telugu": "te", "thai": "th", "tibetan": "bo",
	"turkish": "tr", "turkmen": "tk", "ukrainian": "uk", "urdu": "ur", "uzbek": "uz",
	"vietnamese": "vi", "welsh": "cy", "yiddish": "yi", "yoruba": "yo",
}
