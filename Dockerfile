FROM cirrusci/flutter:latest

WORKDIR /app
COPY . .

RUN flutter config --enable-web
RUN flutter pub get
RUN flutter build web --release

RUN mkdir -p /vercel/output
RUN cp -r build/web/* /vercel/output/
