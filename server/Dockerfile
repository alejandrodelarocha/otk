FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

ENV OTK_DB=/data/otk.db
VOLUME ["/data"]
EXPOSE 7654

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "7654"]
