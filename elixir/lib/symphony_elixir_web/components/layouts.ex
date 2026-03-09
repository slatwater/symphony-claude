defmodule SymphonyElixirWeb.Layouts do
  @moduledoc """
  Shared layouts for the observability dashboard.
  """

  use Phoenix.Component

  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    assigns = assign(assigns, :csrf_token, Plug.CSRFProtection.get_csrf_token())

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={@csrf_token} />
        <title>Symphony Observability</title>
        <script defer src="/vendor/phoenix_html/phoenix_html.js"></script>
        <script defer src="/vendor/phoenix/phoenix.js"></script>
        <script defer src="/vendor/phoenix_live_view/phoenix_live_view.js"></script>
        <script>
          window.addEventListener("DOMContentLoaded", function () {
            var csrfToken = document
              .querySelector("meta[name='csrf-token']")
              ?.getAttribute("content");

            if (!window.Phoenix || !window.LiveView) return;

            var Hooks = {};
            Hooks.AutoScroll = {
              mounted() {
                this._scrollToBottom();
                this._observer = new MutationObserver(function () {
                  this._scrollToBottom();
                }.bind(this));
                this._observer.observe(this.el, { childList: true, subtree: true });
              },
              updated() {
                this._scrollToBottom();
              },
              destroyed() {
                if (this._observer) this._observer.disconnect();
              },
              _scrollToBottom() {
                this.el.scrollTop = this.el.scrollHeight;
              }
            };

            var liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
              params: {_csrf_token: csrfToken},
              hooks: Hooks
            });

            liveSocket.connect();
            window.liveSocket = liveSocket;
          });
        </script>
        <link rel="stylesheet" href="/dashboard.css" />
        <script>
          (function() {
            var zoom = 1.0;
            function applyZoom(z) {
              zoom = Math.min(2.0, Math.max(0.5, z));
              document.body.style.zoom = zoom;
            }
            document.addEventListener('keydown', function(e) {
              if (e.metaKey || e.ctrlKey) {
                if (e.key === '=' || e.key === '+') { e.preventDefault(); applyZoom(zoom + 0.1); }
                else if (e.key === '-') { e.preventDefault(); applyZoom(zoom - 0.1); }
                else if (e.key === '0') { e.preventDefault(); applyZoom(1.0); }
              }
            });
          })();
        </script>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    ~H"""
    <main class="app-shell">
      {@inner_content}
    </main>
    """
  end
end
