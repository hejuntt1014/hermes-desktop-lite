fn main() {
    #[cfg(windows)]
    {
        println!("cargo:rerun-if-changed=assets/hermes.rc");
        println!("cargo:rerun-if-changed=assets/hermes.ico");
        embed_resource::compile("assets/hermes.rc", embed_resource::NONE)
            .manifest_required()
            .expect("embed Hermes taskbar and executable icon");
    }
}
