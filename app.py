from flask import Flask

app = Flask(__name__)

@app.route("/")
def hello():
    print("Request received")
    return "Hello World!"

if __name__ == "__main__":
    print("Starting application...")
    app.run(host="0.0.0.0", port=80)
