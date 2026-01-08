FROM eclipse-temurin:17-jdk
WORKDIR /app

# Install wget for healthcheck
RUN apt-get update && apt-get install -y wget && rm -rf /var/lib/apt/lists/*

COPY build/libs/service.jar app.jar

EXPOSE 8080

# Use JAVA_OPTS environment variable if provided
ENTRYPOINT ["sh", "-c", "java ${JAVA_OPTS} -jar app.jar"]
