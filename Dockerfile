FROM cirrusci/flutter:latest

WORKDIR /app
COPY . .

RUN flutter config --enable-web
RUN flutter pub get
RUN flutter build web --release

# Put the build output in a subdirectory inside /vercel/output
RUN mkdir -p /vercel/output/static
RUN cp -r build/web/* /vercel/output/static
