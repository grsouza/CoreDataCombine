import Combine
import CoreData
import Foundation

extension NSManagedObjectContext {
  public func publisher<Entity>(
    observing request: NSFetchRequest<Entity>
  ) -> FetchedResultsPublisher<Entity>
  where Entity: NSManagedObject {
    FetchedResultsPublisher(request: request, context: self)
  }
}

extension NSObject {
  @discardableResult
  fileprivate func synchronized<T>(_ block: () throws -> T) rethrows -> T {
    objc_sync_enter(self)
    let result = try block()
    objc_sync_exit(self)
    return result
  }
}

public final class FetchedResultsPublisher<Entity>:
    NSObject, NSFetchedResultsControllerDelegate, Publisher
where Entity: NSManagedObject {

  public typealias Output = [Entity]
  public typealias Failure = Error

  private let request: NSFetchRequest<Entity>
  private let context: NSManagedObjectContext
  private let subject: CurrentValueSubject<[Entity], Error>
  private var resultController: NSFetchedResultsController<Entity>?
  private var subscriptions = 0

  public init(request: NSFetchRequest<Entity>, context: NSManagedObjectContext) {
    if request.sortDescriptors == nil {
      request.sortDescriptors = []
    }

    self.request = request
    self.context = context
    subject = CurrentValueSubject([])
  }

  public func receive<S>(subscriber: S)
  where
    S: Subscriber,
    FetchedResultsPublisher.Failure == S.Failure,
    FetchedResultsPublisher.Output == S.Input
  {
    let start = synchronized { () -> Bool in
      subscriptions += 1
      return subscriptions == 1
    }

    if start {
      resultController = NSFetchedResultsController(
        fetchRequest: request,
        managedObjectContext: context,
        sectionNameKeyPath: nil,
        cacheName: nil
      )

      resultController?.delegate = self

      do {
        try resultController?.performFetch()
        let result = resultController?.fetchedObjects ?? []
        subject.send(result)
      } catch {
        subject.send(completion: .failure(error))
      }
    }

    Subscription(publisher: self, subscriber: AnySubscriber(subscriber))
  }

  public func controllerDidChangeContent(
    _ controller: NSFetchedResultsController<NSFetchRequestResult>
  ) {
    let result = controller.fetchedObjects as? [Entity] ?? []
    subject.send(result)
  }

  private func dropSubscription() {
    let stop = synchronized { () -> Bool in
      subscriptions -= 1
      return subscriptions == 0
    }

    if stop {
      resultController?.delegate = nil
      resultController = nil
    }
  }
}

extension FetchedResultsPublisher {

  private final class Subscription: Combine.Subscription, Cancellable {

    private var publisher: FetchedResultsPublisher?
    private var cancellable: AnyCancellable?

    @discardableResult
    init(publisher: FetchedResultsPublisher, subscriber: AnySubscriber<Output, Failure>) {
      self.publisher = publisher
      subscriber.receive(subscription: self)
      cancellable = publisher.subject.sink(
        receiveCompletion: { completion in
          subscriber.receive(completion: completion)
        },
        receiveValue: { value in
          _ = subscriber.receive(value)
        }
      )
    }

    func request(_ demand: Subscribers.Demand) {}

    func cancel() {
      cancellable?.cancel()
      cancellable = nil
      publisher?.dropSubscription()
      publisher = nil
    }

  }
}
