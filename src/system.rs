use crate::config::Config;
use crate::utils::{run_command, run_command_with_output};
use crate::{die, ewarn, vlog};
use colored::Colorize;
use std::collections::HashSet;

/// Official repo updates (`checkupdates`) plus foreign/AUR lines (`yay -Qu`). Both are
/// merged so `-U` can detect packages like `firefox-pure` that never appear in
/// `checkupdates` output alone.
pub fn check_updates() -> String {
    let repo_res = run_command_with_output("checkupdates", &[], None::<&str>);
    let yay_res = run_command_with_output("yay", &["-Qu"], None::<&str>);

    if let (Err(e1), Err(e2)) = (&repo_res, &yay_res) {
        ewarn!(
            "Could not query pending updates: checkupdates failed ({}); yay -Qu failed ({})",
            e1,
            e2
        );
        return String::new();
    }

    // `yay -Qu` often repeats repo lines already shown by `checkupdates`; keep first-seen order.
    let mut seen = HashSet::new();
    let mut lines = Vec::new();
    for s in [repo_res.as_ref().ok(), yay_res.as_ref().ok()]
        .into_iter()
        .flatten()
    {
        for line in s.lines() {
            let t = line.trim();
            if t.is_empty() {
                continue;
            }
            if seen.insert(t.to_string()) {
                lines.push(t.to_string());
            }
        }
    }
    lines.join("\n")
}

/// `use_refresh_command`: `true` only for **`-RU`** (`command_to_perform_system_update`). Otherwise
/// **`command_to_update_repositories`** (used for **`-R`** alone and **`-U`** without **`-R`**).
/// Always appends `ignore_flag` for each entry in `ignore_packages` and `manual_update_packages`
/// (deduped), so repo packages never replace packages you build with emerge.
pub fn run_system_update(config: &Config, use_refresh_command: bool, verbose: bool) {
    let mut cmd_str = if use_refresh_command {
        config
            .system_update
            .command_to_perform_system_update
            .clone()
    } else {
        config.system_update.command_to_update_repositories.clone()
    };

    let mut seen = HashSet::new();
    for pkg in config
        .system_update
        .ignore_packages
        .iter()
        .chain(config.manual_update_packages.iter())
    {
        if seen.insert(pkg.clone()) {
            cmd_str.push_str(&format!(" {} {}", config.system_update.ignore_flag, pkg));
        }
    }

    vlog!(verbose, "Executing system update: {}", cmd_str);

    // We run it via sh -c to allow complex yay commands from config
    if let Err(e) = run_command("sh", &["-c", &cmd_str], None::<&str>) {
        die!("System update failed: {}", e);
    }
}
