"""
Internal dashboard — Flask application.

In production, this module is imported by gunicorn (see Dockerfile CMD):
    gunicorn --bind 0.0.0.0:8080 --workers 2 app:app

The __main__ block below is only used when running locally for development
(e.g. `python app.py`). It uses Flask's built-in dev server, which is
single-threaded and NOT suitable for production traffic.
"""

from flask import Flask

app = Flask(__name__)


@app.route("/")
def hello():
    return "Hello World!"


if __name__ == "__main__":
    # Dev-only. In production, gunicorn imports `app` directly (see Dockerfile).
    # Port 8080 matches what gunicorn binds to, so local behavior mirrors prod.
    app.run(host="0.0.0.0", port=8080, debug=True)
