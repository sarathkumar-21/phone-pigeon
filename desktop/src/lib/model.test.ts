import { describe, expect, it } from "vitest";
import { formatDuration, isDialable, nameFromMachine, normalizeNumber, otpIn, prettyNumber } from "./model";

describe("numbers", () => {
  it("normalizes formatting but keeps a leading plus", () => {
    expect(normalizeNumber("+91 98450-12345")).toBe("+919845012345");
    expect(normalizeNumber("(555) 010-9999")).toBe("5550109999");
    expect(normalizeNumber("AMAZON")).toBe("AMAZON");
  });
  it("accepts only dialable numbers", () => {
    expect(isDialable("+919845012345")).toBe(true);
    expect(isDialable("12")).toBe(false);
    expect(isDialable("1234567890123456")).toBe(false);
    expect(isDialable("JD-BANK")).toBe(false);
  });
  it("groups international numbers for display", () => {
    expect(prettyNumber("+919845012345")).toBe("+91 98450 12345");
    expect(prettyNumber("+15550109999")).toBe("+1 (555) 010-9999");
    expect(prettyNumber("12345")).toBe("12345");
  });
});

describe("helpers", () => {
  it("finds one-time codes", () => {
    expect(otpIn("Your verification code is 482913. Do not share.")).toBe("482913");
    expect(otpIn("Lunch at 1pm?")).toBeNull();
  });
  it("formats durations", () => {
    expect(formatDuration(65)).toBe("1:05");
    expect(formatDuration(3725)).toBe("1:02:05");
  });
});

describe("nameFromMachine", () => {
  it("finds a first name in common computer names", () => {
    expect(nameFromMachine("Saraths-MacBook-Pro")).toBe("Sarath");
    expect(nameFromMachine("Sarath’s MacBook Pro")).toBe("Sarath");
    expect(nameFromMachine("priya-laptop")).toBe("Priya");
    expect(nameFromMachine("Anita-PC.local")).toBe("Anita");
  });
  it("returns nothing when the name holds no first name", () => {
    expect(nameFromMachine("DESKTOP-4F2K9")).toBe("");
    expect(nameFromMachine("ubuntu")).toBe("");
    expect(nameFromMachine("")).toBe("");
    expect(nameFromMachine("localhost")).toBe("");
  });
});
