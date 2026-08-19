# ============================================================================
#  Vexyon — themed fastfetch greeting.
#  Runs the Vexyon fastfetch config once per genuinely-new interactive terminal.
#  Guards:
#    * fish_greeting only fires for interactive shells (never scripts).
#    * VEXYON_GREETED is exported, so nested interactive fish (subshells) inherit
#      it and skip — the greeting shows once per terminal, not per nested shell.
# ============================================================================
function fish_greeting
    if status is-interactive; and not set -q VEXYON_GREETED
        set -gx VEXYON_GREETED 1
        if command -q fastfetch
            fastfetch --config ~/.config/vexyon/fastfetch.jsonc
        end
    end
end
