// SPDX-License-Identifier: Apache-2.0

package same

// eventNames maps SAME event codes (EEE) to their human names. It is the
// common set from the NWS SAME code list plus the national activations. A code
// not listed here is not guessed; EventName returns it unchanged (invariant
// 12).
var eventNames = map[string]string{
	// National.
	"EAN": "Emergency Action Notification",
	"EAT": "Emergency Action Termination",
	"NIC": "National Information Center",
	"NPT": "National Periodic Test",
	"RMT": "Required Monthly Test",
	"RWT": "Required Weekly Test",
	// Warnings.
	"TOR": "Tornado Warning",
	"SVR": "Severe Thunderstorm Warning",
	"FFW": "Flash Flood Warning",
	"FLW": "Flood Warning",
	"SVW": "Severe Weather Warning",
	"SMW": "Special Marine Warning",
	"BZW": "Blizzard Warning",
	"WSW": "Winter Storm Warning",
	"HWW": "High Wind Warning",
	"HUW": "Hurricane Warning",
	"TRW": "Tropical Storm Warning",
	"TSW": "Tsunami Warning",
	"EWW": "Extreme Wind Warning",
	"DSW": "Dust Storm Warning",
	"FRW": "Fire Warning",
	"AVW": "Avalanche Warning",
	"CDW": "Civil Danger Warning",
	"CEM": "Civil Emergency Message",
	"EQW": "Earthquake Warning",
	"EVI": "Evacuation Immediate",
	"HMW": "Hazardous Materials Warning",
	"LEW": "Law Enforcement Warning",
	"NUW": "Nuclear Power Plant Warning",
	"RHW": "Radiological Hazard Warning",
	"SPW": "Shelter in Place Warning",
	"VOW": "Volcano Warning",
	"LAE": "Local Area Emergency",
	"TOE": "911 Telephone Outage Emergency",
	// Watches and advisories.
	"TOA": "Tornado Watch",
	"SVA": "Severe Thunderstorm Watch",
	"FFA": "Flash Flood Watch",
	"FLA": "Flood Watch",
	"HUA": "Hurricane Watch",
	"TRA": "Tropical Storm Watch",
	"TSA": "Tsunami Watch",
	"WSA": "Winter Storm Watch",
	"BZA": "Blizzard Watch",
	"FFS": "Flash Flood Statement",
	"FLS": "Flood Statement",
	"SVS": "Severe Weather Statement",
	"SPS": "Special Weather Statement",
	"HLS": "Hurricane Statement",
	"ADR": "Administrative Message",
	"AVA": "Avalanche Watch",
	"CAE": "Child Abduction Emergency",
}

// EventName returns the human name for a SAME event code, or the code itself
// when it is not one this table knows.
func EventName(code string) string {
	if n, ok := eventNames[code]; ok {
		return n
	}
	return code
}

// orgNames maps SAME originator codes to their names; used for display, not for
// the record's org field, which keeps the raw code.
var orgNames = map[string]string{
	"EAS": "EAS Participant",
	"WXR": "National Weather Service",
	"CIV": "Civil authorities",
	"PEP": "Primary Entry Point System",
}

// OrgName returns the human name for an originator code, or the code unchanged.
func OrgName(code string) string {
	if n, ok := orgNames[code]; ok {
		return n
	}
	return code
}
