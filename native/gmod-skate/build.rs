fn main() {
    // CI's run number, printed on load so a player can tell which build they have.
    println!("cargo:rerun-if-env-changed=GITHUB_RUN_NUMBER");
}
