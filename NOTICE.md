# Notice

Dashboard DL is a fork of **[Dashboard](https://github.com/cucu0628/omarchy-dashboard)**
by **[cucu0628](https://github.com/cucu0628)**, used and redistributed under the
MIT License.

Everything this plugin does apart from downloading — the bar clock, the calendar,
the Overview / Media / Weather views, the MPRIS transport and volume controls,
the system status readout, and the Open-Meteo weather integration — is cucu0628's
work. This fork adds a yt-dlp download button to the Media view and nothing else.

The fork keeps the upstream commit history, so `git log` attributes every original
commit to its author. Upstream is available as a git remote:

```bash
git remote add upstream https://github.com/cucu0628/omarchy-dashboard.git
git log --oneline upstream/main
```

If you only want the dashboard and not the download button, install the original
instead — it is listed on the Omarchy marketplace as `cucu0628.dashboard`:

```bash
omarchy plugin add https://github.com/cucu0628/omarchy-dashboard.git --enable --yes
```

## Third-party runtime dependencies

- **[yt-dlp](https://github.com/yt-dlp/yt-dlp)** (Unlicense) — invoked as an
  external process for the download feature. Not bundled or redistributed here;
  it must be installed separately.
- **[Open-Meteo](https://open-meteo.com/)** (CC BY 4.0 data) — weather data,
  fetched over HTTPS by the upstream Weather view.

## Screenshots

The screenshots in `screenshots/` show the plugin downloading
*Cosmos Laundromat - First Cycle*, a Blender Foundation open movie released
under [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/).
