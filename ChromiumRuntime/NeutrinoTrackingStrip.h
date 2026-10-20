// SPDX-License-Identifier: MPL-2.0
// Removes click and campaign identifiers from top-level Chromium addresses and opens
// AMP pages from their publisher, as WebKit tabs do through Rust's strip_tracking.
// Keep the parameter list in step with TRACKING_PARAMETERS in features.rs.
#pragma once
#include <algorithm>
#include <cctype>
#include <set>
#include <string>
#include <vector>

namespace neutrino_tracking {

inline std::string Lower(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  return value;
}

inline bool EndsWith(const std::string& value, const std::string& suffix) {
  return value.size() >= suffix.size() && value.compare(value.size() - suffix.size(), suffix.size(), suffix) == 0;
}

inline std::string Host(const std::string& url) {
  const size_t start = url.find("://");
  if (start == std::string::npos) return "";
  const size_t end = url.find_first_of("/?#:", start + 3);
  return Lower(url.substr(start + 3, end == std::string::npos ? std::string::npos : end - start - 3));
}

// The publisher's address for Google's AMP viewer and the AMP cache, or "".
inline std::string DeAmp(const std::string& url) {
  for (const std::string prefix : {"https://www.google.com/amp/s/", "https://google.com/amp/s/"})
    if (url.rfind(prefix, 0) == 0 && url.size() > prefix.size()) return "https://" + url.substr(prefix.size());
  const std::string host = Host(url);
  if (!EndsWith(host, ".cdn.ampproject.org")) return "";
  const size_t path = url.find('/', url.find("://") + 3);
  if (path == std::string::npos) return "";
  for (const std::string prefix : {"/c/s/", "/v/s/"})
    if (url.compare(path, prefix.size(), prefix) == 0 && url.size() > path + prefix.size()) return "https://" + url.substr(path + prefix.size());
  return "";
}

// The address without tracking parameters, or "" when nothing changes.
inline std::string StripTracking(const std::string& url) {
  if (url.rfind("http://", 0) != 0 && url.rfind("https://", 0) != 0) return "";
  if (const std::string canonical = DeAmp(url); !canonical.empty()) {
    const std::string stripped = StripTracking(canonical);
    return stripped.empty() ? canonical : stripped;
  }
  static const std::set<std::string> names = {
      "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "utm_id", "utm_name",
      "fbclid", "gclid", "gclsrc", "dclid", "msclkid", "mc_cid", "mc_eid", "igshid", "yclid",
      "_hsenc", "_hsmi", "mkt_tok", "oly_anon_id", "oly_enc_id", "vero_id", "wickedid", "twclid",
      "ttclid", "srsltid", "ref_src", "si"};
  const size_t hash = url.find('#');
  const std::string fragment = hash == std::string::npos ? "" : url.substr(hash);
  const std::string head = hash == std::string::npos ? url : url.substr(0, hash);
  const size_t question = head.find('?');
  if (question == std::string::npos) return "";
  const std::string base = head.substr(0, question), query = head.substr(question + 1);
  const std::string host = Host(url);
  // "si" is only a tracker on a few share links; keep it everywhere else.
  const bool share = EndsWith(host, "youtube.com") || EndsWith(host, "youtu.be") || EndsWith(host, "spotify.com");
  std::vector<std::string> kept;
  bool removed = false;
  size_t offset = 0;
  while (offset <= query.size()) {
    const size_t end = query.find('&', offset);
    const std::string piece = query.substr(offset, end == std::string::npos ? std::string::npos : end - offset);
    const std::string key = Lower(piece.substr(0, piece.find('=')));
    if (!piece.empty() && names.count(key) && (key != "si" || share)) removed = true;
    else if (!piece.empty()) kept.push_back(piece);
    if (end == std::string::npos) break;
    offset = end + 1;
  }
  if (!removed) return "";
  std::string joined;
  for (const std::string& piece : kept) joined += (joined.empty() ? "" : "&") + piece;
  return base + (joined.empty() ? "" : "?" + joined) + fragment;
}

}  // namespace neutrino_tracking
