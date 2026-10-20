// SPDX-License-Identifier: MPL-2.0
// Address rules from subscribed filter lists that are anchored to a host, such as
// ||example.com/ads/* or ||ads.example^*banner$third-party. Rules are indexed by
// host, so a request checks only the rules for its host and parent domains.
// The Rust parser (features.rs parse_patterns_up_to) decides which rules arrive here.
#pragma once
#include <cctype>
#include <string>
#include <unordered_map>
#include <vector>

namespace neutrino_filter {

struct Rule {
  std::string tail;      // The rule after its host, with '*' and '^' wildcards.
  bool end = false;      // The rule ended with '|': the address must end there too.
  bool third = false;    // $third-party: only requests from another site.
};
using Index = std::unordered_map<std::string, std::vector<Rule>>;

// A separator in filter syntax: anything but a letter, digit or one of _ - . %.
inline bool Separator(char c) {
  return !(std::isalnum(static_cast<unsigned char>(c)) || c == '_' || c == '-' || c == '.' || c == '%');
}

// Whether `p` matches the start of `t`. '*' matches any run; '^' a separator or the end.
inline bool Match(const char* p, const char* t, bool end) {
  for (;;) {
    if (!*p) return !end || !*t;
    if (*p == '*') {
      while (*p == '*') ++p;
      if (!*p) return true;
      for (const char* s = t;; ++s) {
        if (Match(p, s, end)) return true;
        if (!*s) return false;
      }
    }
    if (*p == '^') {
      if (!*t) { ++p; continue; }
      if (!Separator(*t)) return false;
    } else if (*p != *t) {
      return false;
    }
    ++p; ++t;
  }
}

// Adds one "||host<tail>[$third-party]" line. Returns false for anything else.
inline bool Add(Index& index, const std::string& line) {
  if (line.size() < 4 || line.size() > 400 || line.compare(0, 2, "||") != 0) return false;
  std::string body = line.substr(2);
  Rule rule;
  const size_t dollar = body.find('$');
  if (dollar != std::string::npos) {
    rule.third = body.compare(dollar, std::string::npos, "$third-party") == 0;
    if (!rule.third) return false;
    body.resize(dollar);
  }
  const size_t split = body.find_first_of("^/*?");
  if (split == 0 || split == std::string::npos) return false;
  std::string host = body.substr(0, split);
  for (char& c : host) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  rule.tail = body.substr(split);
  if (!rule.tail.empty() && rule.tail.back() == '|') { rule.end = true; rule.tail.pop_back(); }
  int stars = 0;
  for (char c : rule.tail) {
    if (c == '|') return false;
    stars += c == '*';
  }
  if (stars > 3) return false;
  index[host].push_back(std::move(rule));
  return true;
}

// The last two labels of a host, close enough to a site for $third-party.
inline std::string Site(const std::string& host) {
  const size_t last = host.rfind('.');
  if (last == std::string::npos || last == 0) return host;
  const size_t before = host.rfind('.', last - 1);
  return before == std::string::npos ? host : host.substr(before + 1);
}

inline std::string Host(const std::string& url, size_t* end = nullptr) {
  const size_t start = url.find("://");
  if (start == std::string::npos) return "";
  const size_t stop = url.find_first_of("/?#:", start + 3);
  if (end) *end = stop == std::string::npos ? url.size() : stop;
  std::string host = url.substr(start + 3, (stop == std::string::npos ? url.size() : stop) - start - 3);
  for (char& c : host) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  return host;
}

// Whether a request for `url`, made by a document at `from`, matches a rule.
inline bool Blocked(const Index& index, const std::string& url, const std::string& from) {
  if (index.empty() || url.size() > 8192) return false;
  size_t end = 0;
  const std::string host = Host(url, &end);
  if (host.empty()) return false;
  // Rules match case-insensitively; the tail starts right after the host name.
  std::string tail = url.substr(end);
  for (char& c : tail) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  const std::string from_host = Host(from);
  const bool third = from_host.empty() || Site(from_host) != Site(host);
  for (size_t start = 0; start < host.size();) {
    const auto found = index.find(host.substr(start));
    if (found != index.end())
      for (const Rule& rule : found->second)
        if ((!rule.third || third) && Match(rule.tail.c_str(), tail.c_str(), rule.end)) return true;
    const size_t dot = host.find('.', start);
    if (dot == std::string::npos) break;
    start = dot + 1;
  }
  return false;
}

}  // namespace neutrino_filter
